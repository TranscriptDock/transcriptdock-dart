import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:transcriptdock/transcriptdock.dart';

void main() {
  test('sends the key, client headers and idempotency key', () async {
    final seen = <http.Request>[];
    final mock = MockClient((request) async {
      seen.add(request);
      return http.Response('{"id":"job_1","status":"queued"}', 202);
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    final body = {'mode': 'captions_only', 'max_credits': 1};
    final job = await client.createJob(body, idempotencyKey: 'unit-key-0001');
    expect(job['id'], 'job_1');
    final request = seen.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://www.transcriptdock.com/v1/jobs');
    expect(request.headers['authorization'], 'Bearer td_live_unit');
    expect(request.headers['accept'], 'application/json');
    expect(request.headers['idempotency-key'], 'unit-key-0001');
    expect(request.headers['content-type'], 'application/json');
    expect(
      request.headers['user-agent'],
      'transcriptdock-dart/${TranscriptDock.version}',
    );
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    expect(jsonDecode(request.body), body);
  });

  test('encodes IDs and query values', () async {
    final seen = <Uri>[];
    final mock = MockClient((request) async {
      seen.add(request.url);
      return http.Response('{}', 200);
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    await client.getJob('a/b c');
    await client.listJobs(limit: 5, cursor: 'x&y');
    expect(seen[0].toString(), endsWith('/v1/jobs/a%2Fb%20c?wait=0'));
    expect(seen[1].query, 'limit=5&cursor=x%26y');
  });

  test('returns a redirect as an error without following it', () async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      return http.Response('', 302, headers: {'location': '/v1/elsewhere'});
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    try {
      await client.capabilities();
      fail('Expected an ApiError');
    } on ApiError catch (error) {
      expect(error.status, 302);
      expect(error.code, 'HTTP_ERROR');
    }
    expect(calls, 1);
  });

  test('keeps API error fields and redacts credentials', () async {
    final mock = MockClient((request) async {
      final error = {
        'error': {'code': 'UNAUTHORIZED', 'message': 'Bearer td_live_unit'},
        'request_id': 'req_1',
      };
      return http.Response(jsonEncode(error), 401);
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    try {
      await client.usage();
      fail('Expected an ApiError');
    } on ApiError catch (error) {
      expect(error.status, 401);
      expect(error.code, 'UNAUTHORIZED');
      expect(error.retryable, isFalse);
      expect(error.requestId, 'req_1');
      expect(error.message, isNot(contains('td_live_unit')));
    }
  });

  test('maps transport failures to NETWORK_ERROR', () async {
    final mock = MockClient((request) async {
      throw http.ClientException('connection refused');
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    try {
      await client.getJob('job_1');
      fail('Expected an ApiError');
    } on ApiError catch (error) {
      expect(error.code, 'NETWORK_ERROR');
      expect(error.retryable, isTrue);
      expect(error.status, isNull);
    }
  });

  test('stops polling at the deadline with the last job', () async {
    final mock = MockClient((request) async {
      return http.Response('{"id":"job_1","status":"processing"}', 200);
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    try {
      await client.waitForJob(
        'job_1',
        timeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 10),
      );
      fail('Expected a JobTimeoutError');
    } on JobTimeoutError catch (error) {
      expect(error.job?['status'], 'processing');
    }
  });

  test('accepts HTTPS and loopback HTTP origins only', () {
    final mock = MockClient((request) async => http.Response('{}', 200));
    const allowed = [
      'https://api.example.com/',
      'http://localhost:8080',
      'http://127.0.0.2:3000',
      'http://[::1]:3000',
    ];
    for (final url in allowed) {
      TranscriptDock('td_live_unit', baseUrl: url, httpClient: mock);
    }
    const rejected = [
      'http://example.com',
      'http://127.example.com',
      'https://example.com#top',
      'ftp://example.com',
    ];
    for (final url in rejected) {
      expect(
        () => TranscriptDock('td_live_unit', baseUrl: url, httpClient: mock),
        throwsArgumentError,
      );
    }
  });

  test('rejects unsafe requests before sending them', () async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      return http.Response('{}', 200);
    });
    final client = TranscriptDock('td_live_unit', httpClient: mock);
    Future<void> rejects(Future<Object?> pending) {
      return expectLater(pending, throwsArgumentError);
    }

    await rejects(client.request('get', '/v1/usage'));
    await rejects(client.request('GET', '/v1/a/%2E/b'));
    await rejects(client.request('GET', 'https://example.com/v1/'));
    await rejects(client.request('POST', '/v1/jobs/job_1/retry', body: {}));
    await rejects(client.exportTranscript('t_1', format: 'pdf'));
    await rejects(client.getTranscript('..'));
    expect(calls, 0);
  });
}
