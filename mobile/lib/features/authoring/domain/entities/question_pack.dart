import 'package:equatable/equatable.dart';

import 'authored_question.dart';

/// One entry of an uploaded question file the parser refused, and why.
///
/// This is a *file* problem, found before anything was sent: a missing question
/// text, an option list with a hole in it, an answer key the shape cannot carry.
/// It is deliberately not a server refusal — a row the database rejects is
/// reported by the widget from the repository's own sentence, because by then
/// the questions before it have already been stored.
class QuestionPackProblem extends Equatable {
  const QuestionPackProblem({required this.line, required this.message});

  /// The 1-based line of a CSV (counting the header as line 1), or the 1-based
  /// position of a question object in a JSON file — the number the author can
  /// count to in whatever opened the file.
  final int line;

  final String message;

  @override
  List<Object?> get props => [line, message];
}

/// A parsed batch of questions: the drafts worth saving, the entries that will
/// not be sent, and the reason the file could not be read at all.
///
/// [drafts] are [QuestionDraft]s rather than rows, so an uploaded question and a
/// typed one travel the same path: the same local shape check, the same
/// `createQuestion` call, and the same database constraints behind both.
///
/// [fileError] and [problems] are refusals of different scope. A file error
/// means *no* entry can be attributed — an unreadable file, a missing `question`
/// column — so nothing is sent; a problem is one entry, so the rest of the paper
/// still arrives.
class QuestionPackParse extends Equatable {
  const QuestionPackParse({
    this.drafts = const <QuestionDraft>[],
    this.problems = const <QuestionPackProblem>[],
    this.fileError,
  });

  final List<QuestionDraft> drafts;
  final List<QuestionPackProblem> problems;
  final String? fileError;

  bool get isEmpty => drafts.isEmpty && problems.isEmpty && fileError == null;

  bool get hasNothingToSend => fileError != null || drafts.isEmpty;

  @override
  List<Object?> get props => [drafts, problems, fileError];
}
