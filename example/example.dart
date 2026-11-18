import 'dart:io';
import 'dart:math';

import 'package:transcriptdock/transcriptdock.dart';

/// Returns a random key for one intended submission.
String newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<void> main() async {
  final apiKey = Platform.environment['TRANSCRIPTDOCK_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set TRANSCRIPTDOCK_API_KEY first.');
    exitCode = 64;
    return;
  }
  final client = TranscriptDock(apiKey);
  try {
    print(await client.capabilities());

    // Generate once per intended operation. Save this key and the job ID.
    // Reuse the same key and exact body if a submission's response is lost.
    final submissionKey = newIdempotencyKey();
    final body = {
      'source': {'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
      'mode': 'captions_only',
      'max_credits': 1,
    };
    var job = await client.createJob(body, idempotencyKey: submissionKey);
    try {
      job = await client.waitForJob(job['id'] as String);
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
  } on ApiError catch (error) {
    print('${error.code} ${error.status} ${error.requestId}');
  } finally {
    client.close();
  }
}
