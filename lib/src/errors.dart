import 'dart:async';

/// An API or transport failure.
///
/// Requests are never retried automatically. Use [retryable] and
/// [retryAfterSeconds] together with the operation's idempotency rules to
/// decide whether to retry.
class ApiError implements Exception {
  /// Creates an error. The client builds these for you.
  ApiError(
    this.code,
    this.message, {
    this.status,
    this.retryable = false,
    this.requestId,
    this.retryAfterSeconds,
  });

  /// The API error code.
  ///
  /// Transport failures and timeouts use `NETWORK_ERROR`. Responses that are
  /// not a UTF-8 JSON object use `INVALID_RESPONSE`. Error responses without
  /// an API error code use `HTTP_ERROR`.
  final String code;

  /// A readable description with bearer tokens and API keys redacted.
  final String message;

  /// The HTTP status, or null when no response arrived.
  final int? status;

  /// Whether the API says the same request may succeed later.
  final bool retryable;

  /// The API request ID to quote when contacting support.
  final String? requestId;

  /// How long the API asks you to wait before retrying, if it says.
  final num? retryAfterSeconds;

  @override
  String toString() {
    final where = status == null ? '' : ' (HTTP $status)';
    return 'ApiError $code$where: $message';
  }
}

/// Thrown when `waitForJob` reaches its deadline.
///
/// The job keeps running on the server. [job] holds the last observed job, or
/// null when no poll completed.
class JobTimeoutError extends TimeoutException {
  /// Creates a timeout error holding the last observed [job].
  JobTimeoutError(this.job)
      : super('The job is still running. Check it again using its ID.');

  /// The last job response, or null when no poll completed.
  final Map<String, dynamic>? job;

  @override
  String toString() => 'JobTimeoutError: $message';
}
