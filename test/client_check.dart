// Contract checks shared by every Transcript Dock SDK.
//
// Run `python3 .ci/check.py`, which starts the loopback fixture in
// .ci/fixture.py and then runs this program. Nothing here reaches production
// or spends credits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:transcriptdock/transcriptdock.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<T> raises<T extends Object>(FutureOr<Object?> Function() action) async {
  try {
    await action();
  } on T catch (error) {
    return error;
  }
  throw StateError('Expected $T');
}

Future<ArgumentError> invalid(FutureOr<Object?> Function() action) {
  return raises<ArgumentError>(action);
}

bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

Map<String, dynamic> sent(Map<String, dynamic> out) =>
    out['request'] as Map<String, dynamic>;

Future<void> main() async {
  final base = Platform.environment['TRANSCRIPTDOCK_TEST_BASE_URL']!;
  final client = TranscriptDock('td_live_fixture_only', baseUrl: base);
  try {
    await run(client);
  } finally {
    client.close();
  }
  print('Dart client checks passed');
}

Future<void> run(TranscriptDock client) async {
  Future<ApiError> fails(String path) {
    return raises<ApiError>(() => client.request('GET', path));
  }

  const replayKey = 'fixture-replay-01';
  final body = {
    'source': {'url': 'https://example.com/video'},
    'mode': 'captions_only',
    'max_credits': 1,
  };
  for (var i = 0; i < 2; i++) {
    final out = await client.createJob(body, idempotencyKey: replayKey);
    check(out['future_field'] == 42, 'future response field lost');
    final request = sent(out);
    check(same(request['body'], body), 'request body changed');
    check(request['idempotency_key'] == replayKey, 'headers changed');
    check(request['authorized'] == true, 'headers changed');
  }

  final listed = await client.request(
    'GET',
    '/v1/jobs',
    query: {'cursor': 'a/b?c&d', 'limit': 7},
  );
  final query = sent(listed)['query'] as Map<String, dynamic>;
  check(same(query['cursor'], ['a/b?c&d']), 'cursor encoding changed');

  final job = await client.getJob('id/other?x');
  final path = sent(job)['path'] as String;
  check(path.endsWith('id%2Fother%3Fx'), 'ID path encoding changed');

  final transcript = await client.getTranscript('fixture');
  final words = transcript['words'] as List<dynamic>;
  final first = words.first as Map<String, dynamic>;
  check(first['start_ms'] == 123, 'timing unit changed');

  final srt = await client.exportTranscript('fixture', format: 'srt');
  check(srt.contains('fixture'), 'export lost');

  for (final status in ['succeeded', 'failed', 'cancelled']) {
    final done = await client.waitForJob(status);
    check(done['status'] == status, 'terminal status lost');
  }
  final timedOut = await raises<JobTimeoutError>(() {
    return client.waitForJob(
      'processing',
      timeout: const Duration(milliseconds: 150),
      pollInterval: const Duration(seconds: 1),
    );
  });
  check(timedOut.job?['status'] == 'processing', 'timeout lost last job');

  final limited = await fails('/v1/rate-limit');
  check(limited.status == 429, 'API error fields lost');
  check(limited.retryable, 'API error fields lost');
  check(limited.retryAfterSeconds == 4, 'API error fields lost');
  check(limited.requestId == 'fixture-request', 'API error fields lost');
  check(!limited.message.contains('td_live_fixture_only'), 'key in error');
  check(!'$limited'.contains('td_live_fixture_only'), 'key in error');

  final redirected = await fails('/v1/redirect');
  check(redirected.status == 302, 'redirect followed');
  for (final name in ['gateway', 'error-shape', 'malformed', 'array']) {
    await fails('/v1/$name');
  }

  const submissions = [
    '/v1/batches',
    '/v1/video-discoveries',
    '/v1/language-discoveries',
  ];
  for (final submission in submissions) {
    await invalid(() => client.request('POST', submission, body: {}));
    final out = await client.request(
      'POST',
      submission,
      body: {'fixture': true},
      idempotencyKey: 'fixture-generic-01',
    );
    check(sent(out)['method'] == 'POST', 'generic submission failed');
  }

  final deleted = await client.request('DELETE', '/v1/transcripts/fixture');
  check(sent(deleted)['method'] == 'DELETE', 'delete dispatch failed');

  const badOrigins = [
    'http://example.com',
    'https://user:pass@example.com',
    'https://example.com/path',
    'https://example.com?x=1',
  ];
  for (final url in badOrigins) {
    await invalid(() => TranscriptDock('fixture-key', baseUrl: url));
  }
  await invalid(() => TranscriptDock('bad\nkey'));
  await invalid(() => client.createJob({}, idempotencyKey: 'bad\nreplay'));
  await invalid(() => client.request('GET', '/v1/../secret'));
  // Durations cannot be NaN, so zero and negative limits stand in for it.
  const negative = Duration(milliseconds: -1);
  await invalid(() => client.waitForJob('fixture', timeout: Duration.zero));
  await invalid(() => client.waitForJob('fixture', timeout: negative));

  final slow = await raises<ApiError>(() {
    return client.request(
      'GET',
      '/v1/slow',
      timeout: const Duration(milliseconds: 30),
    );
  });
  check(slow.code == 'NETWORK_ERROR', 'transport timeout not handled');

  await invalid(() => client.request('post', '/v1/jobs', body: {}));
  await invalid(() => client.request('get', '/v1/capabilities'));
  await invalid(() => client.request('GET', '/v1/%2e%2e/secret'));

  const lost = 'budget, replay conflict or inaccessible job error lost';
  const rejections = {
    'budget': [402, 'BUDGET_EXCEEDED'],
    'conflict': [409, 'IDEMPOTENCY_CONFLICT'],
    'jobs/not-owned': [404, 'NOT_FOUND'],
  };
  for (final entry in rejections.entries) {
    final error = await fails('/v1/${entry.key}');
    check(error.status == entry.value[0], lost);
    check(error.code == entry.value[1], lost);
    check(!error.retryable, lost);
  }
}
