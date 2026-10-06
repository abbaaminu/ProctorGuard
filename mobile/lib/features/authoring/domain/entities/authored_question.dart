import 'package:equatable/equatable.dart';

import '../../../exam/domain/entities/question.dart';

/// A question as its **owner** sees it: the lecturer console reads
/// `public.questions` directly (never `questions_public`), which is the only
/// place `correct_option` / `correct_text_answer` exist on the client — the
/// authoring screens are the one audience the answer key is for.
///
/// Nothing here is sent anywhere: every write is built from a [QuestionDraft],
/// so the shape rules live in one place whether a row is being created or
/// edited.
class AuthoredQuestion extends Equatable {
  const AuthoredQuestion({
    required this.id,
    required this.examId,
    required this.questionText,
    required this.questionType,
    required this.options,
    required this.correctOption,
    required this.correctTextAnswer,
    required this.points,
  });

  factory AuthoredQuestion.fromMap(Map<String, dynamic> map) =>
      AuthoredQuestion(
        id: map['id'] as String,
        examId: map['exam_id'] as String,
        questionText: map['question_text'] as String? ?? '',
        questionType: QuestionType.fromDb(map['question_type'] as String?),
        options: List<String>.from(
          (map['options'] as List?) ?? const <String>[],
        ),
        correctOption: (map['correct_option'] as num?)?.toInt(),
        correctTextAnswer: map['correct_text_answer'] as String?,
        points: (map['points'] as num?)?.toDouble() ?? 1,
      );

  final String id;
  final String examId;
  final String questionText;
  final QuestionType questionType;
  final List<String> options;

  /// The 0-based index of the right option — `multiple_choice` only.
  final int? correctOption;

  /// The accepted wording — `fill_in_the_blank` (graded trimmed and
  /// case-insensitively), or the word `true` / `false` for `true_false`. Null
  /// for an essay, which has no key to grade against.
  final String? correctTextAnswer;

  final double points;

  /// The answer key as a lecturer reads it back in the question list: the option
  /// text rather than its index, and "no key — marked by hand" for an essay.
  /// Never a bare blank, because an empty row reads as a bug rather than a
  /// shape.
  String get answerSummary => switch (questionType) {
        QuestionType.multipleChoice => _optionText() ?? 'No correct option set',
        QuestionType.trueFalse => _trueFalseSummary(),
        QuestionType.fillInTheBlank => _fillInSummary(),
        QuestionType.subjective => 'No answer key — marked by hand',
      };

  String? _optionText() {
    final index = correctOption;
    if (index == null || index < 0 || index >= options.length) return null;
    return options[index];
  }

  String _trueFalseSummary() {
    final value = (correctTextAnswer ?? '').trim().toLowerCase();
    return switch (value) {
      'true' => 'True',
      'false' => 'False',
      _ => 'No correct answer set',
    };
  }

  String _fillInSummary() {
    final value = (correctTextAnswer ?? '').trim();
    return value.isEmpty ? 'No accepted answer set' : '“$value”';
  }

  /// Re-opens this row in the editor.
  QuestionDraft toDraft() => QuestionDraft(
        questionType: questionType,
        questionText: questionText,
        options: options,
        correctOption: correctOption,
        correctTextAnswer: correctTextAnswer ?? '',
        points: points,
      );

  @override
  List<Object?> get props => [
        id,
        examId,
        questionText,
        questionType,
        options,
        correctOption,
        correctTextAnswer,
        points,
      ];
}

/// What the editor produces, and the **only** thing a write is built from.
///
/// The rules mirror `questions_answer_key_shape` and
/// `questions_question_type_check` in `supabase/schema.sql`, so the console
/// refuses locally what the database would refuse with a raw `23514`, and the
/// lecturer reads a sentence instead of a constraint name. The database keeps
/// its own copy of the rule regardless: a patched client is not a reason to
/// trust a check.
class QuestionDraft extends Equatable {
  const QuestionDraft({
    required this.questionType,
    required this.questionText,
    this.options = const <String>[],
    this.correctOption,
    this.correctTextAnswer = '',
    this.points = 1,
  });

  /// The fewest tap targets a multiple-choice question can have. One option is
  /// not a choice, and the database cannot tell a one-option row from a
  /// mis-built one.
  static const minOptions = 2;

  /// The most one question should offer; also the point at which the editor's
  /// option list stops being readable on a phone.
  static const maxOptions = 6;

  /// The floor `questions_points_non_negative` enforces, and the ceiling the
  /// editor offers. Zero is allowed (an unweighted item is not a bug); a
  /// negative weight would let a paper mark itself down.
  static const minPoints = 0.0;
  static const maxPoints = 100.0;

  /// A brand-new draft of [questionType], pre-filled the way the editor opens
  /// it: the multiple-choice starter pair, and — for every other type — the
  /// empty answer the validator then asks for.
  factory QuestionDraft.blank(QuestionType questionType) => QuestionDraft(
        questionType: questionType,
        questionText: '',
        options: questionType.isMultipleChoice
            ? const <String>['', '']
            : const <String>[],
      );

  final QuestionType questionType;
  final String questionText;
  final List<String> options;
  final int? correctOption;
  final String correctTextAnswer;
  final double points;

  QuestionDraft copyWith({
    QuestionType? questionType,
    String? questionText,
    List<String>? options,
    int? correctOption,
    bool clearCorrectOption = false,
    String? correctTextAnswer,
    double? points,
  }) =>
      QuestionDraft(
        questionType: questionType ?? this.questionType,
        questionText: questionText ?? this.questionText,
        options: options ?? this.options,
        correctOption:
            clearCorrectOption ? null : (correctOption ?? this.correctOption),
        correctTextAnswer: correctTextAnswer ?? this.correctTextAnswer,
        points: points ?? this.points,
      );

  /// Whether a true/false draft has 'true' selected (the other state being
  /// 'false'), for the editor's segmented control.
  bool get isTrue => correctTextAnswer.trim().toLowerCase() == 'true';

  /// The first reason this draft cannot be stored, or null when it is complete.
  ///
  /// One message in the order a lecturer fills the form in, rather than a list to
  /// reconcile: the editor shows it beside the field in question, and the
  /// database's own constraint stays the authority either way.
  String? get problem {
    if (questionText.trim().isEmpty) return 'Write the question.';

    if (points < minPoints) return 'Marks cannot be negative.';
    if (points > maxPoints) return 'Marks cannot exceed $maxPoints.';

    switch (questionType) {
      case QuestionType.multipleChoice:
        if (options.length < minOptions) {
          return 'A multiple-choice question needs at least $minOptions '
              'options.';
        }
        if (options.any((option) => option.trim().isEmpty)) {
          return 'Every option needs text.';
        }
        final index = correctOption;
        if (index == null || index < 0 || index >= options.length) {
          return 'Pick which option is correct.';
        }
      case QuestionType.trueFalse:
        final value = correctTextAnswer.trim().toLowerCase();
        if (value != 'true' && value != 'false') {
          return 'Choose whether the answer is true or false.';
        }
      case QuestionType.fillInTheBlank:
        if (correctTextAnswer.trim().isEmpty) {
          return 'Type the answer you will accept.';
        }
      case QuestionType.subjective:
        // Nothing to ask for: the absence of a key is the whole shape.
        break;
    }

    return null;
  }

  bool get isComplete => problem == null;

  /// The row to insert or update.
  ///
  /// The answer key is written for the type in front of it and deliberately
  /// cleared for the others, so editing a row into another shape can never leave
  /// a stale key behind — the shape constraint would reject that, but only after
  /// the update had already been sent.
  Map<String, dynamic> toRow() {
    final isChoice = questionType.isMultipleChoice;
    final hasTypedKey =
        questionType.isFillInTheBlank || questionType.isTrueFalse;

    return <String, dynamic>{
      'question_text': questionText.trim(),
      'question_type': questionType.dbValue,
      'options': isChoice
          ? options.map((option) => option.trim()).toList()
          : const <String>[],
      'correct_option': isChoice ? correctOption : null,
      'correct_text_answer': hasTypedKey
          // Stored lowercase for true/false: `submit_exam` compares the words
          // case-insensitively anyway, and one canonical spelling keeps the row
          // readable in SQL.
          ? (questionType.isTrueFalse
              ? correctTextAnswer.trim().toLowerCase()
              : correctTextAnswer.trim())
          : null,
      'points': points,
    };
  }

  @override
  List<Object?> get props => [
        questionType,
        questionText,
        options,
        correctOption,
        correctTextAnswer,
        points,
      ];
}
