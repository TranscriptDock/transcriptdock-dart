import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

const _methods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'};
const _submissions = {
  '/v1/jobs',
  '/v1/batches',
  '/v1/video-discoveries',
  '/v1/language-discoveries',
};
const _terminal = {'succeeded', 'failed', 'cancelled'};
const _formats = {'json', 'txt', 'srt', 'vtt'};
const _isWeb = bool.fromEnvironment('dart.library.js_interop');
const _networkMessage =
    'Could not reach the API. Check the job before retrying a submission.';

final _keyPattern = RegExp(r'^[ -~]{8,128}$');
final _percent = RegExp('%([0-9A-Fa-f]{2})');
final _secret =
    RegExp(r'td_live_[A-Za-z0-9_-]+|Bearer\s+\S+', caseSensitive: false);

/// An asynchronous client for the Transcript Dock public API.
///
/// Runs on the Dart VM and on every Flutter platform. Responses are decoded
/// JSON objects that keep every field the API returns, including fields added
/// after this release. Requests never follow redirects and are never retried
/// automatically.
class TranscriptDock {
  /// Creates a client that sends [apiKey] as a bearer token.
  ///
  /// [baseUrl] must be an HTTPS origin, or HTTP on loopback for local
  /// development, without credentials, path, query or fragment. [timeout]
  /// applies to each request. Pass [httpClient] to use your own client;
  /// [close] leaves an injected client open.
  ///
  /// Throws [ArgumentError] for an invalid key, origin or timeout.
  TranscriptDock(
    String apiKey, {
    String baseUrl = defaultBaseUrl,
    Duration timeout = const Duration(seconds: 30),
    http.Client? httpClient,
  })  : _apiKey = _checkApiKey(apiKey),
        _baseUrl = _checkOrigin(baseUrl),
        timeout = _positive(timeout, 'timeout'),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// The package version sent in the `User-Agent` header.
  static const String version = '0.1.0';

  /// The production API origin.
  static const String defaultBaseUrl = 'https://www.transcriptdock.com';

  final String _apiKey;
  final String _baseUrl;
  final http.Client _http;
  final bool _ownsClient;

  /// The default limit for each request.
  final Duration timeout;

  /// Closes the HTTP client this instance created.
  ///
  /// An injected client stays open, so close it yourself.
  void close() {
    if (_ownsClient) _http.close();
  }

  /// Calls a public `/v1/` endpoint and returns its JSON object.
  ///
  /// [method] must be an uppercase HTTP method. Pass query parameters in
  /// [query]; null values are dropped. POST submissions to `/v1/jobs`,
  /// `/v1/batches`, `/v1/video-discoveries`, `/v1/language-discoveries` and
  /// any path ending in `/retry` need an [idempotencyKey].
  ///
  /// Throws [ApiError] for API and transport failures and [ArgumentError]
  /// for invalid input.
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    String? idempotencyKey,
    Duration? timeout,
  }) async {
    final raw = await _send(
      method,
      path,
      body: body,
      query: query,
      idempotencyKey: idempotencyKey,
      timeout: timeout,
    );
    Object? result;
    try {
      result = jsonDecode(raw);
    } on FormatException {
      throw _invalid('The API did not return JSON.');
    }
    if (result is! Map<String, dynamic>) {
      throw _invalid('The API did not return a JSON object.');
    }
    return result;
  }

  /// Calls a public `/v1/` endpoint and returns the body as text.
  ///
  /// Accepts the same arguments as [request]. Use it for endpoints that
  /// return files, such as transcript exports.
  Future<String> requestText(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    String? idempotencyKey,
    Duration? timeout,
  }) async {
    return _send(
      method,
      path,
      body: body,
      query: query,
      idempotencyKey: idempotencyKey,
      timeout: timeout,
    );
  }

  /// Returns the modes, sources and limits available to this API key.
  Future<Map<String, dynamic>> capabilities() async {
    return request('GET', '/v1/capabilities');
  }

  /// Returns credit balance and usage for this API key.
  Future<Map<String, dynamic>> usage() async {
    return request('GET', '/v1/usage');
  }

  /// Submits a transcription job. This can spend credits.
  ///
  /// Generate [idempotencyKey] once per intended job and save it. Replay the
  /// same body with the same key if the response is lost.
  Future<Map<String, dynamic>> createJob(
    Map<String, Object?> body, {
    required String idempotencyKey,
  }) async {
    return _post('/v1/jobs', body, idempotencyKey);
  }

  /// Returns a job. A positive [wait] asks the API to hold the request
  /// up to that many seconds for a status change.
  Future<Map<String, dynamic>> getJob(String jobId, {int wait = 0}) async {
    return request('GET', _path('/v1/jobs', jobId), query: {'wait': wait});
  }

  /// Lists jobs, newest first. Pass the returned cursor to continue.
  Future<Map<String, dynamic>> listJobs({
    int limit = 20,
    String? cursor,
  }) async {
    final query = {'limit': limit, 'cursor': cursor};
    return request('GET', '/v1/jobs', query: query);
  }

  /// Cancels a job that has not finished.
  Future<Map<String, dynamic>> cancelJob(String jobId) async {
    return request('POST', _path('/v1/jobs', jobId, '/cancel'));
  }

  /// Retries a failed job. This can spend credits.
  Future<Map<String, dynamic>> retryJob(
    String jobId, {
    required String idempotencyKey,
    num? maxCredits,
  }) async {
    final body = {if (maxCredits != null) 'max_credits': maxCredits};
    return _post(_path('/v1/jobs', jobId, '/retry'), body, idempotencyKey);
  }

  /// Polls a job until it succeeds, fails or is cancelled.
  ///
  /// Returns the terminal job, so check its status before using
  /// `result_id`. Throws [JobTimeoutError] with the last observed job when
  /// [timeout] passes. The job keeps running on the server.
  Future<Map<String, dynamic>> waitForJob(
    String jobId, {
    Duration timeout = const Duration(seconds: 120),
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final limit = _positive(timeout, 'timeout');
    _positive(pollInterval, 'pollInterval');
    final path = _path('/v1/jobs', jobId);
    final clock = Stopwatch()..start();
    Map<String, dynamic>? job;
    while (true) {
      var remaining = limit - clock.elapsed;
      if (remaining <= Duration.zero) throw JobTimeoutError(job);
      final wait = _shorter(this.timeout, remaining);
      job = await request('GET', path, timeout: wait);
      if (_terminal.contains(job['status'])) return job;
      remaining = limit - clock.elapsed;
      if (remaining <= Duration.zero) throw JobTimeoutError(job);
      await Future<void>.delayed(_sleepFor(_shorter(pollInterval, remaining)));
    }
  }

  /// Returns a transcript with its raw timing fields.
  Future<Map<String, dynamic>> getTranscript(String transcriptId) async {
    return request('GET', _path('/v1/transcripts', transcriptId));
  }

  /// Exports a transcript as `json`, `txt`, `srt` or `vtt` text.
  Future<String> exportTranscript(
    String transcriptId, {
    String format = 'txt',
  }) async {
    if (!_formats.contains(format)) {
      throw ArgumentError('Choose json, txt, srt or vtt.');
    }
    final path = _path('/v1/transcripts', transcriptId, '/export');
    return requestText('GET', path, query: {'format': format});
  }

  /// Deletes a transcript.
  Future<Map<String, dynamic>> deleteTranscript(String transcriptId) async {
    return request('DELETE', _path('/v1/transcripts', transcriptId));
  }

  /// Submits a batch of jobs. This can spend credits.
  Future<Map<String, dynamic>> createBatch(
    Map<String, Object?> body, {
    required String idempotencyKey,
  }) async {
    return _post('/v1/batches', body, idempotencyKey);
  }

  /// Returns a batch.
  Future<Map<String, dynamic>> getBatch(String batchId) async {
    return request('GET', _path('/v1/batches', batchId));
  }

  /// Starts discovering videos from a channel, playlist or profile.
  Future<Map<String, dynamic>> createVideoDiscovery(
    Map<String, Object?> body, {
    required String idempotencyKey,
  }) async {
    return _post('/v1/video-discoveries', body, idempotencyKey);
  }

  /// Returns a video discovery.
  Future<Map<String, dynamic>> getVideoDiscovery(String discoveryId) async {
    return request('GET', _path('/v1/video-discoveries', discoveryId));
  }

  /// Starts discovering the caption languages of a video.
  Future<Map<String, dynamic>> createLanguageDiscovery(
    Map<String, Object?> body, {
    required String idempotencyKey,
  }) async {
    return _post('/v1/language-discoveries', body, idempotencyKey);
  }

  /// Returns a language discovery.
  Future<Map<String, dynamic>> getLanguageDiscovery(String discoveryId) async {
    return request('GET', _path('/v1/language-discoveries', discoveryId));
  }

  /// Requests an upload slot.
  ///
  /// Send the file bytes to the returned signed URL yourself, without your
  /// Transcript Dock API key, then call [completeUpload].
  Future<Map<String, dynamic>> createUpload(Map<String, Object?> body) async {
    return _post('/v1/uploads', body, null);
  }

  /// Marks an upload as complete after its bytes are stored.
  Future<Map<String, dynamic>> completeUpload(String uploadId) async {
    return _post(_path('/v1/uploads', uploadId, '/complete'), null, null);
  }

  /// Lists webhook endpoints.
  Future<Map<String, dynamic>> listWebhookEndpoints() async {
    return request('GET', '/v1/webhook-endpoints');
  }

  /// Creates a webhook endpoint. Store the returned secret privately.
  Future<Map<String, dynamic>> createWebhookEndpoint(
    Map<String, Object?> body,
  ) async {
    return _post('/v1/webhook-endpoints', body, null);
  }

  /// Deletes a webhook endpoint.
  Future<Map<String, dynamic>> deleteWebhookEndpoint(String endpointId) async {
    return request('DELETE', _path('/v1/webhook-endpoints', endpointId));
  }

  Future<Map<String, dynamic>> _post(String path, Object? body, String? key) {
    return request('POST', path, body: body, idempotencyKey: key);
  }

  Future<String> _send(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    String? idempotencyKey,
    Duration? timeout,
  }) async {
    if (!_methods.contains(method)) {
      throw ArgumentError('Provide a supported uppercase HTTP method.');
    }
    if (!path.startsWith('/v1/') || path.contains(RegExp(r'[?#\\]'))) {
      throw ArgumentError(
          'Use a /v1/ path and pass query parameters separately.');
    }
    final decoded = path.replaceAllMapped(_percent, _byte);
    if (decoded.split('/').any((part) => part == '.' || part == '..')) {
      throw ArgumentError('API paths cannot contain traversal segments.');
    }
    final submission = _submissions.contains(path) || path.endsWith('/retry');
    if (method == 'POST' && submission && idempotencyKey == null) {
      throw ArgumentError('Provide an idempotency key for this submission.');
    }
    if (idempotencyKey != null && !_keyPattern.hasMatch(idempotencyKey)) {
      throw ArgumentError(
          'Idempotency keys need 8 to 128 printable ASCII characters.');
    }
    final limit = _positive(timeout ?? this.timeout, 'timeout');
    final abort = Completer<void>();
    final outgoing = http.AbortableRequest(
      method,
      _url(path, query),
      abortTrigger: abort.future,
    );
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;
    outgoing.headers['Authorization'] = 'Bearer $_apiKey';
    outgoing.headers['Accept'] = 'application/json';
    if (!_isWeb) {
      // Browsers control the User-Agent header themselves.
      outgoing.headers['User-Agent'] = 'transcriptdock-dart/$version';
    }
    if (idempotencyKey != null) {
      outgoing.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (body != null) {
      outgoing.headers['Content-Type'] = 'application/json';
      outgoing.bodyBytes = utf8.encode(_encodeBody(body));
    }
    final http.Response response;
    try {
      response = await _exchange(outgoing).timeout(limit);
    } on Exception {
      if (!abort.isCompleted) abort.complete();
      throw ApiError('NETWORK_ERROR', _networkMessage, retryable: true);
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) throw _apiError(status, response);
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      throw _invalid('The API response is not UTF-8 text.');
    }
  }

  Future<http.Response> _exchange(http.BaseRequest request) async {
    return http.Response.fromStream(await _http.send(request));
  }

  Uri _url(String path, Map<String, Object?>? query) {
    final pairs = <String>[];
    for (final entry in (query ?? const <String, Object?>{}).entries) {
      final value = entry.value;
      if (value != null) {
        pairs.add('${_encodeQuery(entry.key)}=${_encodeQuery('$value')}');
      }
    }
    final search = pairs.isEmpty ? '' : '?${pairs.join('&')}';
    try {
      return Uri.parse('$_baseUrl$path$search');
    } on FormatException {
      throw ArgumentError('Provide a valid API path.');
    }
  }

  ApiError _apiError(int status, http.Response response) {
    Object? envelope;
    try {
      envelope = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      envelope = null;
    }
    final root = envelope is Map ? envelope : const <String, Object?>{};
    final error = root['error'];
    final detail = error is Map ? error : const <String, Object?>{};
    var message = detail['message'];
    if (message == null || message == '') {
      message = 'Request failed with status $status.';
    }
    var retryable = status == 429 || status >= 500;
    if (detail.containsKey('retryable')) {
      retryable = detail['retryable'] == true;
    }
    final rawId = root['request_id'];
    final requestId = rawId == null || rawId == '' ? null : _redact(rawId);
    final retryAfter = detail['retry_after_seconds'];
    return ApiError(
      _redact(detail['code'] ?? 'HTTP_ERROR'),
      _redact(message),
      status: status,
      retryable: retryable,
      requestId: requestId,
      retryAfterSeconds: retryAfter is num ? retryAfter : null,
    );
  }

  String _redact(Object? value) {
    final text = '$value'.replaceAll(_apiKey, '[REDACTED]');
    return text.replaceAll(_secret, '[REDACTED]');
  }
}

String _checkApiKey(String apiKey) {
  if (apiKey.isEmpty || apiKey.codeUnits.any((c) => c < 33 || c > 126)) {
    throw ArgumentError(
        'Provide an API key without whitespace or control characters.');
  }
  return apiKey;
}

String _checkOrigin(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  final host = uri?.host ?? '';
  final secure = uri?.scheme == 'https';
  final local = uri?.scheme == 'http' && _isLoopback(host);
  if (uri == null || host.isEmpty || !(secure || local)) {
    throw ArgumentError(
        'Use an HTTPS origin, or HTTP on loopback for local development.');
  }
  if (uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.port > 65535) {
    throw ArgumentError(
        'Use an origin without credentials, path, query or fragment.');
  }
  if (!baseUrl.endsWith('/')) return baseUrl;
  return baseUrl.substring(0, baseUrl.length - 1);
}

bool _isLoopback(String host) {
  if (host == 'localhost') return true;
  try {
    if (!host.contains(':')) return Uri.parseIPv4Address(host)[0] == 127;
    final bytes = Uri.parseIPv6Address(host);
    return bytes.indexWhere((byte) => byte != 0) == 15 && bytes[15] == 1;
  } on FormatException {
    return false;
  }
}

Duration _positive(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError('$name must be a positive duration.');
  }
  return value;
}

Duration _shorter(Duration a, Duration b) => a < b ? a : b;

// VM timers count whole milliseconds and can fire up to one early, so round
// up and add one to never wake before the deadline.
Duration _sleepFor(Duration value) {
  return Duration(milliseconds: (value.inMicroseconds + 999) ~/ 1000 + 1);
}

String _encodeId(String value) {
  if (value.isEmpty || value == '.' || value == '..') {
    throw ArgumentError('Provide a nonempty ID.');
  }
  return Uri.encodeComponent(value);
}

String _path(String prefix, String id, [String suffix = '']) {
  return '$prefix/${_encodeId(id)}$suffix';
}

String _encodeBody(Object body) {
  try {
    return jsonEncode(body);
  } on JsonUnsupportedObjectError {
    throw ArgumentError('The request body must be JSON encodable.');
  }
}

String _byte(Match m) => String.fromCharCode(int.parse(m[1]!, radix: 16));

String _encodeQuery(String value) => Uri.encodeQueryComponent(value);

ApiError _invalid(String message) => ApiError('INVALID_RESPONSE', message);
