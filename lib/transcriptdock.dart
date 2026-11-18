/// Client for the Transcript Dock video transcription API.
///
/// Create a [TranscriptDock] client with your API key, submit jobs with an
/// explicit idempotency key and poll them with a deadline. Failures raise
/// [ApiError]; polling deadlines raise [JobTimeoutError].
library;

export 'src/client.dart' show TranscriptDock;
export 'src/errors.dart' show ApiError, JobTimeoutError;
