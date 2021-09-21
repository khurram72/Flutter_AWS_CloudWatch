library aws_cloudwatch;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:aws_request/aws_request.dart';
import 'package:synchronized/synchronized.dart';
import 'package:universal_io/io.dart';

// AWS Hard Limits
const String _GROUP_NAME_REGEX_PATTERN = r'^[\.\-_/#A-Za-z0-9]+$';
const String _STREAM_NAME_REGEX_PATTERN = r'^[^:*]*$';

class CloudWatchException implements Exception {
  String message;
  StackTrace stackTrace;

  /// A custom error to identify CloudWatch errors more easily
  ///
  /// message: the cause of the error
  /// stackTrace: the stack trace of the error
  CloudWatchException(this.message, this.stackTrace);
}

/// An enum representing what should happen to messages that are too big
/// to be sent as a single message. This limit is 262118 utf8 bytes
///
/// truncate: Replace the middle of the message with "...", making it 262118
///           utf8 bytes long. This is the default value.
///
/// ignore: Ignore large messages. They will not be sent
///
/// split: Split large messages into multiple smaller messages and send them
///
/// error: Throw an error when a large message is encountered
enum CloudWatchLargeMessages {
  /// Replace the middle of the message with "...", making it 262118 utf8 bytes
  /// long. This is the default value.
  truncate,

  /// Ignore large messages. They will not be sent
  ignore,

  /// Split large messages into multiple smaller messages and send them
  split,

  /// Throw an error when a large message is encountered
  error,
}

/// A CloudWatch handler class to easily manage multiple CloudWatch instances
class CloudWatchHandler {
  Map<String, CloudWatch> _logInstances = {};

  /// Your AWS Access key.
  String awsAccessKey;

  /// Your AWS Secret key.
  String awsSecretKey;

  /// Your AWS region.
  String region;

  /// How long to wait between requests to avoid rate limiting (suggested value is Duration(milliseconds: 200))
  Duration delay;

  /// How long to wait for request before triggering a timeout
  Duration requestTimeout;

  /// How many times an api request should be retired upon failure. Default is 3
  int retries;

  /// How messages larger than AWS limit should be handled. Default is truncate.
  CloudWatchLargeMessages largeMessageBehavior;

  /// CloudWatchHandler Constructor
  CloudWatchHandler({
    required this.awsAccessKey,
    required this.awsSecretKey,
    required this.region,
    this.delay: const Duration(milliseconds: 0),
    this.requestTimeout: const Duration(seconds: 10),
    this.retries: 3,
    this.largeMessageBehavior: CloudWatchLargeMessages.truncate,
  }) {
    this.retries = max(1, this.retries);
  }

  /// Returns a specific instance of a CloudWatch class (or null if it doesnt
  /// exist) based on group name and stream name
  ///
  /// Uses the [logGroupName] and the [logStreamName] to find the correct
  /// CloudWatch instance. Returns null if it doesnt exist
  CloudWatch? getInstance({
    required String logGroupName,
    required String logStreamName,
  }) {
    String instanceName = '$logGroupName.$logStreamName';
    return _logInstances[instanceName];
  }

  /// Logs the provided message to the provided log group and log stream
  ///
  /// Logs a single [msg] to [logStreamName] under the group [logGroupName]
  Future<void> log({
    required String msg,
    required String logGroupName,
    required String logStreamName,
  }) async {
    await logMany(
      messages: [msg],
      logGroupName: logGroupName,
      logStreamName: logStreamName,
    );
  }

  /// Logs the provided message to the provided log group and log stream
  ///
  /// Logs a list of string [messages] to [logStreamName] under the group [logGroupName]
  ///
  /// Note: using logMany will result in all logs having the same timestamp
  Future<void> logMany({
    required List<String> messages,
    required String logGroupName,
    required String logStreamName,
  }) async {
    CloudWatch instance = getInstance(
          logGroupName: logGroupName,
          logStreamName: logStreamName,
        ) ??
        _createInstance(
          logGroupName: logGroupName,
          logStreamName: logStreamName,
        );
    await instance.logMany(messages);
  }

  CloudWatch _createInstance({
    required String logGroupName,
    required String logStreamName,
  }) {
    String instanceName = '$logGroupName.$logStreamName';
    CloudWatch instance = CloudWatch(
      awsAccessKey,
      awsSecretKey,
      region,
      groupName: logGroupName,
      streamName: logStreamName,
      delay: delay,
      requestTimeout: requestTimeout,
      retries: retries,
      largeMessageBehavior: largeMessageBehavior,
    );
    _logInstances[instanceName] = instance;
    return instance;
  }
}

/// An AWS CloudWatch class for sending logs more easily to AWS
class CloudWatch {
  // AWS Variables
  /// Public AWS access key
  String awsAccessKey;

  /// Private AWS access key
  String awsSecretKey;

  /// AWS region
  String region;

  /// How long to wait between requests to avoid rate limiting (suggested value is Duration(milliseconds: 200))
  Duration delay;

  /// How long to wait for request before triggering a timeout
  Duration requestTimeout;

  /// How many times an api request should be retired upon failure. Default is 3
  int retries;

  /// How messages larger than AWS limit should be handled. Default is truncate.
  CloudWatchLargeMessages largeMessageBehavior;

  // Logging Variables
  /// The log group the log stream will appear under
  String? groupName;

  /// Synonym for groupName
  String? get logGroupName => groupName;

  set logGroupName(String? val) => groupName = val;

  /// The log stream name for log events to be filed in
  String? streamName;

  /// Synonym for streamName
  String? get logStreamName => streamName;

  set logStreamName(String? val) => streamName = val;

  int _verbosity = 0;
  String? _sequenceToken;
  late CloudWatchLogStack _logStack;
  var _loggingLock = Lock();
  bool _logStreamCreated = false;
  bool _logGroupCreated = false;

  /// CloudWatch Constructor
  CloudWatch(
    this.awsAccessKey,
    this.awsSecretKey,
    this.region, {
    this.groupName,
    this.streamName,
    this.delay: const Duration(milliseconds: 0),
    this.requestTimeout: const Duration(seconds: 10),
    this.retries: 3,
    this.largeMessageBehavior: CloudWatchLargeMessages.truncate,
  }) {
    delay = !delay.isNegative ? delay : Duration(milliseconds: 0);
    this.retries = max(1, this.retries);
    this._logStack =
        CloudWatchLogStack(largeMessageBehavior: largeMessageBehavior);
  }

  /// Sets how long to wait between requests to avoid rate limiting
  ///
  /// Sets the delay to be [delay]
  Duration setDelay(Duration delay) {
    this.delay = !delay.isNegative ? delay : Duration(milliseconds: 0);
    _debugPrint(
      2,
      'CloudWatch INFO: Set delay to $delay',
    );
    return delay;
  }

  /// Sets log group name and log stream name
  ///
  /// Sets the [logGroupName] and [logStreamName]
  void setLoggingParameters(String? logGroupName, String? logStreamName) {
    groupName = logGroupName;
    streamName = logStreamName;
  }

  /// Sends a log to AWS
  ///
  /// Sends the [logString] to AWS to be added to the CloudWatch logs
  ///
  /// Throws a [CloudWatchException] if [groupName] or [streamName] are not
  /// initialized or if aws returns an error.
  Future<void> log(String logString) async {
    await logMany([logString]);
  }

  /// Sends a log to AWS
  ///
  /// Sends a list of strings [logStrings] to AWS to be added to the CloudWatch logs
  ///
  /// Note: using logMany will result in all logs having the same timestamp
  ///
  /// Throws a [CloudWatchException] if [groupName] or [streamName] are not
  /// initialized or if aws returns an error.
  Future<void> logMany(List<String> logStrings) async {
    _debugPrint(
      2,
      'CloudWatch INFO: Attempting to log many',
    );
    if ([groupName, streamName].contains(null)) {
      _debugPrint(
        0,
        'CloudWatch ERROR: Please supply a Log Group and Stream names by '
        'calling setLoggingParameters(String? groupName, String? streamName)',
      );
      throw CloudWatchException(
          'CloudWatch ERROR: Please supply a Log Group and Stream names by '
          'calling setLoggingParameters(String groupName, String streamName)',
          StackTrace.current);
    }
    _validateName(
      groupName!,
      'groupName',
      _GROUP_NAME_REGEX_PATTERN,
    );
    _validateName(
      streamName!,
      'streamName',
      _STREAM_NAME_REGEX_PATTERN,
    );
    await _log(logStrings);
  }

  /// Sets console verbosity level.
  /// Useful for debugging.
  /// Hidden by default. Get here with a debugger ;)
  ///
  /// 0 - Errors only
  /// 1 - Status Codes
  /// 2 - General Info
  void _setVerbosity(int level) {
    level = min(level, 3);
    level = max(level, 0);
    _verbosity = level;
    _debugPrint(
      2,
      'CloudWatch INFO: Set verbosity to $_verbosity',
    );
  }

  void _debugPrint(int v, String msg) {
    if (_verbosity > v) {
      print(msg);
    }
  }

  Future<void> _createLogStreamAndLogGroup() async {
    dynamic error;
    for (int i = 0; i < retries; i++) {
      try {
        await _createLogStream();
        return;
      } on CloudWatchException catch (e) {
        if (e.message.contains('ResourceNotFoundException')) {
          // Create a new log group and try stream creation again
          await _createLogGroup();
          await _createLogStream();
          return;
        }
        error = e;
      } catch (e) {
        error = e;
        _debugPrint(
          0,
          'CloudWatch ERROR: Failed _createLogStreamAndLogGroup. Retrying ${i + 1}',
        );
      }
    }
    throw error;
  }

  Future<void> _createLogStream() async {
    if (!_logStreamCreated) {
      _debugPrint(
        2,
        'CloudWatch INFO: Generating LogStream',
      );
      _logStreamCreated = true;
      String body =
          '{"logGroupName": "$groupName","logStreamName": "$streamName"}';
      HttpClientResponse log = await AwsRequest(
        awsAccessKey,
        awsSecretKey,
        region,
        service: 'logs',
        timeout: requestTimeout,
      ).send(
        AwsRequestType.POST,
        jsonBody: body,
        target: 'Logs_20140328.CreateLogStream',
      );
      int statusCode = log.statusCode;
      _debugPrint(
        1,
        'CloudWatch Info: LogStream creation status code: $statusCode',
      );
      if (statusCode != 200) {
        Map<String, dynamic>? reply = jsonDecode(
          await log.transform(utf8.decoder).join(),
        );
        _debugPrint(
          0,
          'CloudWatch ERROR: StatusCode: $statusCode, CloudWatchResponse: $reply',
        );
        _logStreamCreated = false;
        throw CloudWatchException(
            'CloudWatch ERROR: $reply', StackTrace.current);
      }
    }
    _debugPrint(
      2,
      'CloudWatch INFO: Got LogStream',
    );
  }

  Future<void> _createLogGroup() async {
    if (!_logGroupCreated) {
      _debugPrint(
        2,
        'CloudWatch INFO: creating LogGroup Exists',
      );
      _logGroupCreated = true;
      String body = '{"logGroupName": "$groupName"}';
      HttpClientResponse log = await AwsRequest(
        awsAccessKey,
        awsSecretKey,
        region,
        service: 'logs',
        timeout: requestTimeout,
      ).send(
        AwsRequestType.POST,
        jsonBody: body,
        target: 'Logs_20140328.CreateLogGroup',
      );
      int statusCode = log.statusCode;
      _debugPrint(
        1,
        'CloudWatch Info: LogGroup creation status code: $statusCode',
      );
      if (statusCode != 200) {
        Map<String, dynamic>? reply = jsonDecode(
          await log.transform(utf8.decoder).join(),
        );
        _debugPrint(
          0,
          'CloudWatch ERROR: StatusCode: $statusCode, AWS Response: $reply',
        );
        _logGroupCreated = false;
        throw CloudWatchException(
            'CloudWatch ERROR: $reply', StackTrace.current);
      }
    }
    _debugPrint(
      2,
      'CloudWatch INFO: created LogGroup',
    );
  }

  // turns a string into a cloudwatch event
  String _createBody(List<Map<String, dynamic>> logsToSend) {
    _debugPrint(
      2,
      'CloudWatch INFO: Generating CloudWatch request body',
    );
    Map<String, dynamic> body = {
      'logEvents': logsToSend,
      'logGroupName': groupName,
      'logStreamName': streamName,
    };
    if (_sequenceToken != null) {
      body['sequenceToken'] = _sequenceToken;
      _debugPrint(
        2,
        'CloudWatch INFO: Adding sequence token',
      );
    }
    String jsonBody = json.encode(body);
    _debugPrint(
      2,
      'CloudWatch INFO: Generated jsonBody with ${logsToSend.length} logs: $jsonBody',
    );
    return jsonBody;
  }

  Future<void> _log(List<String> logStrings) async {
    _logStack.addLogs(logStrings);
    _debugPrint(
      2,
      'CloudWatch INFO: Added messages to log stack',
    );
    dynamic error;
    if (!_logStreamCreated) {
      await _loggingLock
          .synchronized(_createLogStreamAndLogGroup)
          .catchError((e) {
        error = e;
      });
    }
    if (error != null) {
      throw error;
    }
    await _sendAllLogs().catchError((e) {
      error = e;
    });
    if (error != null) {
      throw error;
    }
  }

  Future<void> _sendAllLogs() async {
    dynamic error;
    while (_logStack.length > 0 && error == null) {
      await Future.delayed(
        delay,
        () async => await _loggingLock.synchronized(_sendLogs),
      ).catchError((e) {
        error = e;
      });
    }
    if (error != null) {
      throw error;
    }
  }

  Future<void> _sendLogs() async {
    if (_logStack.length <= 0) {
      // logs already sent while this request was waiting for lock
      _debugPrint(
        2,
        'CloudWatch INFO: All logs have already been sent',
      );
      return;
    }
    // capture logs that are about to be sent in case the request fails
    CloudWatchLog _logs = _logStack.pop();
    bool success = false;
    dynamic error;
    for (int i = 0; i < retries && !success; i++) {
      try {
        HttpClientResponse? response = await _sendRequest(_logs);
        success = await _handleResponse(response);
      } catch (e) {
        _debugPrint(
          0,
          'CloudWatch ERROR: Failed making AwsRequest. Retrying ${i + 1}',
        );
        error = e;
      }
    }
    if (!success) {
      // prepend logs in event of failure
      _logStack.prepend(_logs);
      _debugPrint(
        0,
        'CloudWatch ERROR: Failed to send logs',
      );
      if (error != null) throw error;
    }
  }

  Future<HttpClientResponse?> _sendRequest(CloudWatchLog _logs) async {
    String body = _createBody(_logs.logs);
    HttpClientResponse? result;
    result = await AwsRequest(
      awsAccessKey,
      awsSecretKey,
      region,
      service: 'logs',
      timeout: requestTimeout,
    ).send(
      AwsRequestType.POST,
      jsonBody: body,
      target: 'Logs_20140328.PutLogEvents',
    );
    return result;
  }

  /// Handles the [response] from the cloudwatch api.
  ///
  /// Returns whether or not the call was successful
  Future<bool> _handleResponse(
    HttpClientResponse? response,
  ) async {
    if (response == null) {
      _debugPrint(
        0,
        'CloudWatch ERROR: Null response received from AWS',
      );
      throw CloudWatchException(
          'CloudWatch ERROR: Null response received from AWS',
          StackTrace.current);
    }
    int statusCode = response.statusCode;
    Map<String, dynamic> reply = jsonDecode(
      await response.transform(utf8.decoder).join(),
    );
    if (statusCode == 200) {
      _debugPrint(
        1,
        'CloudWatch Info: StatusCode: $statusCode, AWS Response: $reply',
      );
      _sequenceToken = reply['nextSequenceToken'];
      return true;
    } else {
      if (reply.containsKey('__type')) {
        return await _handleError(reply);
      }
      _debugPrint(
        0,
        'CloudWatch ERROR: StatusCode: $statusCode, AWS Response: $reply',
      );
      // failed for unknown reason. Throw error
      throw CloudWatchException(
          'CloudWatch ERROR: StatusCode: $statusCode, AWS Response: $reply',
          StackTrace.current);
    }
  }

  Future<bool> _handleError(Map<String, dynamic> reply) async {
    if (reply['__type'] == 'InvalidSequenceTokenException' &&
        reply['expectedSequenceToken'] != _sequenceToken) {
      // bad sequence token
      // Sometimes happen when requests are sent in quick succession
      // Attempt to recover
      _sequenceToken = reply['expectedSequenceToken'];
      _debugPrint(
        0,
        'CloudWatch Info: Found incorrect sequence token. Attempting to fix.',
      );
      return false;
    } else if (reply['__type'] == 'ResourceNotFoundException' &&
        reply['message'] == "The specified log stream does not exist.") {
      // LogStream not present
      // Sometimes happens with debuggers / hot reloads
      // Attempt to recover
      _debugPrint(
        0,
        'CloudWatch Info: Log Stream doesnt Exist',
      );
      _logStreamCreated = false;
      await _createLogStream();
      return false;
    } else if (reply['__type'] == 'ResourceNotFoundException' &&
        reply['message'] == "The specified log group does not exist.") {
      // LogGroup not present
      // Sometimes happens with debuggers / hot reloads
      // Attempt to recover
      _debugPrint(
        0,
        'CloudWatch Info: Log Group doesnt Exist',
      );
      _logGroupCreated = false;
      await _createLogGroup();
      return false;
    } else if (reply['__type'] == 'DataAlreadyAcceptedException') {
      // This log set has already been sent.
      // Sometimes happens with debuggers / hot reloads
      // Update the sequence token just in case.
      // A previous request was already successful => return true
      _debugPrint(
        0,
        'CloudWatch Info: Data Already Sent',
      );
      _sequenceToken = reply['expectedSequenceToken'];
      return true;
    }
    return false;
  }

  void _validateName(String name, String type, String pattern) {
    if (name.length > 512 || name.length == 0) {
      throw CloudWatchException(
        'Provided $type "$name" is invalid. $type must be between 1 and 512 characters.',
        StackTrace.current,
      );
    }
    if (!RegExp(pattern).hasMatch(name)) {
      throw CloudWatchException(
        'Provided $type "$name" doesnt match pattern $pattern required of $type',
        StackTrace.current,
      );
    }
  }
}

/// A class to hold logs and their metadata
class CloudWatchLog {
  /// The list of logs in json form. These are ready to be sent
  List<Map<String, dynamic>> logs = [];

  /// The utf8 byte size of the logs contained within [logs]
  int messageSize = 0;

  /// Constructor for a LogObject
  CloudWatchLog({required this.logs, required this.messageSize});
}

/// A class that automatically splits and handles logs according to AWS hard limits
class CloudWatchLogStack {
  /// An enum value that indicates how messages larger than the max size should be treated
  CloudWatchLargeMessages largeMessageBehavior;

  static const int _AWS_MAX_BYTE_MESSAGE_SIZE = 262118;
  static const int _AWS_MAX_BYTE_BATCH_SIZE = 1048550;
  static const int _AWS_MAX_MESSAGES_PER_BATCH = 10000;

  CloudWatchLogStack({
    required this.largeMessageBehavior,
  });

  /// The stack of logs that holds presplt CloudWatchLogs
  List<CloudWatchLog> logStack = [];

  /// The length of the stack
  int get length => logStack.length;

  /// Splits up [logStrings] and processes them in prep to add them to the [logStack]
  ///
  /// Prepares [logStrings] using selected [largeMessageBehavior] as needed
  /// taking care to mind aws hard limits.
  void addLogs(List<String> logStrings) {
    int time = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (String msg in logStrings) {
      List<int> bytes = utf8.encode(msg);
      // AWS hard limit on message size
      if (bytes.length <= _AWS_MAX_BYTE_MESSAGE_SIZE) {
        addToStack(time, bytes);
      } else {
        switch (largeMessageBehavior) {

          /// Truncate message by replacing middle with "..."
          case CloudWatchLargeMessages.truncate:
            // plus 3 to account for "..."
            int toRemove =
                ((bytes.length - _AWS_MAX_BYTE_MESSAGE_SIZE + 3) / 2).ceil();
            int midPoint = (bytes.length / 2).floor();
            List<int> newMessage = bytes.sublist(0, midPoint - toRemove) +
                // "..." in bytes (2e)
                [46, 46, 46] +
                bytes.sublist(midPoint + toRemove);
            addToStack(time, newMessage);
            break;

          /// Split up large message into multiple smaller ones
          case CloudWatchLargeMessages.split:
            while (bytes.length > _AWS_MAX_BYTE_MESSAGE_SIZE) {
              addToStack(
                time,
                bytes.sublist(0, _AWS_MAX_BYTE_MESSAGE_SIZE),
              );
              bytes = bytes.sublist(_AWS_MAX_BYTE_MESSAGE_SIZE);
            }
            addToStack(time, bytes);
            break;

          /// Ignore the message
          case CloudWatchLargeMessages.ignore:
            continue;

          /// Throw an error
          case CloudWatchLargeMessages.error:
            throw CloudWatchException(
              'Provided log message is too long. Individual message size limit is '
              '$_AWS_MAX_BYTE_MESSAGE_SIZE. log message: $msg',
              StackTrace.current,
            );
        }
      }
    }
  }

  /// Adds logs to the last CloudWatchLog
  ///
  /// Adds a json object of [time] and decoded [bytes] to the last CloudWatchLog
  /// on the last [logStack] Creates a new CloudWatchLog as needed.
  void addToStack(int time, List<int> bytes) {
    // empty list / aws hard limits on batch sizes
    if (logStack.length == 0 ||
        logStack.last.logs.length >= _AWS_MAX_MESSAGES_PER_BATCH ||
        logStack.last.messageSize + bytes.length > _AWS_MAX_BYTE_BATCH_SIZE) {
      logStack.add(
        CloudWatchLog(
          logs: [
            {
              'timestamp': time,
              'message': utf8.decode(bytes),
            },
          ],
          messageSize: bytes.length,
        ),
      );
    } else {
      logStack.last.logs
          .add({'timestamp': time, 'message': utf8.decode(bytes)});
      logStack.last.messageSize += bytes.length;
    }
  }

  /// Pops off first CloudWatchLog from the [logStack] and returns it
  CloudWatchLog pop() {
    CloudWatchLog result = logStack.first;
    if (logStack.length > 1) {
      logStack = logStack.sublist(1);
    } else {
      logStack.clear();
    }
    return result;
  }

  /// Prepends a CloudWatchLog to the [logStack]
  void prepend(CloudWatchLog messages) {
    // this is the fastest prepend until ~1700 items
    logStack = [messages, ...logStack];
  }
}
