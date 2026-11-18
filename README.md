# Transcript Dock for Dart and Flutter

An asynchronous client for the [Transcript Dock API](https://www.transcriptdock.com/docs).
Dart 3.4 or newer. Runs on the Dart VM and on Flutter for Android, iOS, web,
macOS, Windows and Linux. The only runtime dependency is
[`package:http`](https://pub.dev/packages/http).

Install from pub.dev:

```sh
dart pub add transcriptdock
# or, in a Flutter app
flutter pub add transcriptdock
```

For local development, run `dart pub get` from this directory.

## Submit and read a transcript

Set `TRANSCRIPTDOCK_API_KEY` in your environment. Keep it out of source control.

```dart
import 'dart:io';

import 'package:transcriptdock/transcriptdock.dart';

Future<void> main() async {
  final client = TranscriptDock(Platform.environment['TRANSCRIPTDOCK_API_KEY']!);
  try {
    print(await client.capabilities());

    // Generate once per intended operation. Save this key and the returned job ID.
    // Reuse the same key and exact body if a submission's response is lost.
    const submissionKey = 'replace-with-a-unique-key-per-operation';
    var job = await client.createJob({
      'source': {'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
      'mode': 'captions_only',
      'max_credits': 1,
    }, idempotencyKey: submissionKey);

    try {
      job = await client.waitForJob(job['id'] as String,
          timeout: const Duration(minutes: 2));
    } on JobTimeoutError catch (error) {
      print('Still running: ${error.job}');
      return;
    }
    if (job['status'] == 'succeeded') {
      final resultId = job['result_id'] as String;
      print(await client.getTranscript(resultId));
      print(await client.exportTranscript(resultId, format: 'srt'));
    } else {
      print('${job['status']} ${job['error']}');
    }
  } finally {
    client.close();
  }
}
```

[`example/example.dart`](example/example.dart) is a runnable version that
generates a random idempotency key.

Creating a job can spend credits. This example caps the request at one credit
and requests captions only. It does not enable AI fallback. Check capabilities
and your plan before selecting other modes. Never blindly resubmit after a
network failure: check the job ID or replay the same body with the same
idempotency key. The client does not retry requests automatically.

## Supported operations

All responses are `Map<String, dynamic>` values that keep the API's fields,
including fields added later. Request bodies use the API's exact field names;
the server validates supported options. See the
[OpenAPI definition](https://www.transcriptdock.com/docs/openapi.yaml) for bodies.

* `capabilities()`, `usage()`
* `createJob(body, idempotencyKey: ...)`, `getJob(id, wait: 0)`,
  `listJobs(limit: 20, cursor: null)`, `cancelJob(id)`,
  `retryJob(id, idempotencyKey: ..., maxCredits: null)`, `waitForJob(id, ...)`
* `getTranscript(id)`, `exportTranscript(id, format: 'txt')`, `deleteTranscript(id)`
* `createBatch(body, idempotencyKey: ...)`, `getBatch(id)`
* `createVideoDiscovery(body, idempotencyKey: ...)`, `getVideoDiscovery(id)`
* `createLanguageDiscovery(body, idempotencyKey: ...)`, `getLanguageDiscovery(id)`
* `createUpload(body)`, `completeUpload(id)`
* `listWebhookEndpoints()`, `createWebhookEndpoint(body)`, `deleteWebhookEndpoint(id)`

`exportTranscript` returns a `String` for JSON, TXT, SRT and VTT, preserving the
export response. `getTranscript` preserves raw timing fields without converting
units. `waitForJob(id, timeout: ..., pollInterval: ...)` returns succeeded,
failed or cancelled jobs; inspect the status before using `result_id`. A timeout
leaves the job running and exposes its last observed response as
`JobTimeoutError.job` (or null if no poll was possible).

`createUpload` creates an upload slot only. Transfer bytes to the returned signed
upload URL separately following the API instructions, without sending your
Transcript Dock API key to the storage host. Then call `completeUpload`.
Webhook secrets are sensitive; store them privately and verify callback
signatures in your receiver according to the API documentation.

`request(method, '/v1/...', body: ..., query: ...)` supports public endpoints
added later, and `requestText` returns the raw body for file responses. Both
take uppercase methods only and reject absolute URLs, traversal paths and
redirects. Custom API origins must use HTTPS, except loopback HTTP for local
development. The default origin is `https://www.transcriptdock.com`; the apex
domain redirects.

## Flutter, web and HTTP clients

Pass `httpClient:` to reuse your own `http.Client`, for example one with custom
TLS settings. `close()` closes only the client that `TranscriptDock` created.
Each request has a deadline (`timeout:`, 30 seconds by default); a deadline that
passes is reported as `NETWORK_ERROR`.

The client sets `followRedirects = false` and `maxRedirects = 0` on every
request. On the Dart VM and on Flutter mobile and desktop, a 3xx response is
therefore returned as an `ApiError` with that status. On Flutter web the browser
controls redirects and ignores these settings, and it also sets the
`User-Agent` header itself.

An API key in a mobile or web app can be extracted by anyone who has the app.
Keep the key on a server you control and call Transcript Dock from there, or
give each user their own key.

## Errors

```dart
try {
  final jobs = await client.listJobs(limit: 10);
  print(jobs);
} on ApiError catch (error) {
  print('${error.code} ${error.status} ${error.requestId}');
  // retryable and retryAfterSeconds describe the API response.
  // Decide whether to retry using the operation's idempotency rules.
}
```

Transport failures and timeouts use `NETWORK_ERROR`; malformed responses use
`INVALID_RESPONSE`. API messages redact bearer tokens and API keys. Error
responses do not expose raw HTML pages. Invalid arguments, such as a missing
idempotency key, throw `ArgumentError` before any request is sent.

## Development and release

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
python3 .ci/check.py
dart pub publish --dry-run
```

`.ci/check.py` starts a loopback fixture server and runs the shared contract
checks in `test/client_check.dart`. Tests spend no credits and never reach
production. `pubspec.lock` pins every dependency for the oldest supported SDK.

Releases go to pub.dev from GitHub Actions. The founder publishes the first
version by hand with `dart pub publish`, signed in with Google, and then enables
automated publishing on the package Admin page:

| Field | Value |
| --- | --- |
| Repository | `TranscriptDock/transcriptdock-dart` |
| Tag pattern | `v{{version}}` |
| Environment | `pub.dev` |

After that, pushing a tag such as `v0.1.0` that matches `pubspec.yaml` runs
`.github/workflows/publish.yml`, which validates and publishes the package with
a short lived OIDC token. No registry secret is stored in the repository. The
normal push workflow checks only. A local build is not a release.

Contact: transcriptdock@volods.com

## License

MIT
