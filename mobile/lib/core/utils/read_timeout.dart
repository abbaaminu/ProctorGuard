import 'dart:async';

/// How long a repository **read** may stay unanswered before it is abandoned.
///
/// The HTTP client underneath `supabase_flutter` has no default timeout, so one
/// socket that never answers holds the future that asked for it for ever: a
/// console sits on its spinner and a student's question feed never resolves, with
/// nothing on screen saying anything went wrong. Twelve seconds is well above a
/// healthy read on a slow mobile connection - the profile gate's single-row read
/// gives itself four (`ProfileRepositoryImpl.defaultAttemptTimeout`) - and short
/// enough that a dead connection reaches the error path the page already has,
/// rather than looking like a hang.
///
/// **Reads only.** A write is not abandoned on this deadline, because a timeout
/// cannot tell "the server refused it" from "the server applied it and the answer
/// was lost". Retrying on that guess is the offline queue's decision, made with
/// the RPC's own codes, not a repository's.
const Duration defaultReadTimeout = Duration(seconds: 12);

/// What a read that ran out of time reports to a person.
///
/// The sentence the repository layer already uses for "the server did not
/// answer" - `SupervisionRepositoryImpl`, `AdminUserRepositoryImpl._guard` and
/// `QuestionAuthoringRepositoryImpl._guard` all say exactly this - so a deadline
/// reads like every other unreachable backend, not like a new kind of failure.
const String readTimeoutMessage =
    'Could not reach the server. Check your connection and try again.';

/// A read that was abandoned at its deadline.
///
/// Not a `PostgrestException`: nothing was refused and nothing was returned.
/// Repositories that wrap their failures in a typed exception turn this into the
/// same sentence a refused connection gets; the ones that let transport errors
/// through hand this to the page, and [toString] *is* the sentence, so a screen
/// that prints `'$error'` prints words rather than `Instance of ...`.
class ReadTimeoutException implements Exception {
  /// [message] is the sentence to show; it is a parameter so a caller can say
  /// which read timed out in a log line without changing what a page prints.
  const ReadTimeoutException([this.message = readTimeoutMessage]);

  final String message;

  @override
  String toString() => message;
}

/// Runs [read] with a deadline, turning "no answer in time" into
/// [ReadTimeoutException].
///
/// [timeout] is a parameter for the same reason
/// `ProfileRepositoryImpl.attemptTimeout` is one: a test that has to wait twelve
/// seconds to see a deadline fire is a test nobody runs.
Future<T> withReadTimeout<T>(
  Future<T> Function() read, {
  Duration timeout = defaultReadTimeout,
}) async {
  try {
    return await read().timeout(timeout);
  } on TimeoutException {
    throw const ReadTimeoutException();
  }
}
