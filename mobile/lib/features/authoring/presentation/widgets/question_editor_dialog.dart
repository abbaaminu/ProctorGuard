import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../exam/domain/entities/question.dart';
import '../../domain/entities/authored_question.dart';

/// The question editor: one form whose answer fields change with the type.
///
/// It owns every field (the page holds no half-filled question), and it refuses
/// to close with an incomplete draft — the sentence shown is [QuestionDraft
/// .problem], which mirrors the shape rules the database enforces
/// (`questions_answer_key_shape`), so a lecturer reads "Pick which option is
/// correct." instead of `23514`.
///
/// Returns the [QuestionDraft] through `Navigator.pop`, or nothing on cancel.
class QuestionEditorDialog extends StatefulWidget {
  const QuestionEditorDialog({super.key, this.existing});

  /// The question being re-opened, or null for a new one.
  final AuthoredQuestion? existing;

  @override
  State<QuestionEditorDialog> createState() => _QuestionEditorDialogState();
}

class _QuestionEditorDialogState extends State<QuestionEditorDialog> {
  /// The draft as the fields currently stand. Never sent as-is: [_save] folds
  /// the controllers into it first, so what leaves this dialog is one coherent
  /// value rather than a mix of state and text.
  late QuestionDraft _draft = widget.existing?.toDraft() ??
      QuestionDraft.blank(QuestionType.multipleChoice);

  late final TextEditingController _questionController =
      TextEditingController(text: _draft.questionText);

  /// The accepted wording — the fill-in-the-blank answer, or 'true'/'false',
  /// which the segmented control reads and writes too.
  late final TextEditingController _answerController =
      TextEditingController(text: _draft.correctTextAnswer);

  late final TextEditingController _pointsController = TextEditingController(
    text: formatPoints(_draft.points),
  );

  late List<TextEditingController> _optionControllers = [
    for (final option in _draft.options) TextEditingController(text: option),
  ];

  /// False until Save is pressed once: the problem sentence is the answer to an
  /// attempt to save, not a rebuke for an empty form the lecturer has just
  /// opened.
  bool _showProblem = false;

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    _pointsController.dispose();
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Marks print without a trailing `.0`; the field is for a person to read.
  static String formatPoints(double points) =>
      points == points.roundToDouble() ? '${points.round()}' : '$points';

  /// Switches the draft's type, carrying over what still means something: the
  /// wording and the marks always, the option list only between two
  /// multiple-choice drafts, and the accepted wording only between the two typed
  /// shapes. Everything else would be a key for a shape that is gone.
  void _setType(QuestionType type) {
    if (type == _draft.questionType) return;

    for (final controller in _optionControllers) {
      controller.dispose();
    }
    final options = type.isMultipleChoice
        ? (_draft.options.isEmpty ? const <String>['', ''] : _draft.options)
        : const <String>[];
    _optionControllers = [
      for (final option in options) TextEditingController(text: option),
    ];

    final keepsTypedAnswer = type.isFillInTheBlank || type.isTrueFalse;
    if (!keepsTypedAnswer) _answerController.clear();

    setState(() {
      _draft = _draft.copyWith(
        questionType: type,
        options: options,
        clearCorrectOption: !type.isMultipleChoice,
        correctTextAnswer: keepsTypedAnswer ? _draft.correctTextAnswer : '',
      );
      _showProblem = false;
    });
  }

  void _updateQuestionText(String value) => setState(
        () => _draft = _draft.copyWith(questionText: value),
      );

  void _updateAnswer(String value) => setState(
        () => _draft = _draft.copyWith(correctTextAnswer: value),
      );

  void _updateOption(int index, String value) {
    final options = List<String>.of(_draft.options);
    options[index] = value;
    setState(() => _draft = _draft.copyWith(options: options));
  }

  void _addOption() {
    if (_draft.options.length >= QuestionDraft.maxOptions) return;
    setState(() {
      _optionControllers = [
        ..._optionControllers,
        TextEditingController(),
      ];
      _draft = _draft.copyWith(
        options: [..._draft.options, ''],
      );
    });
  }

  /// Removes an option and repairs the answer key: an index after the removed
  /// one shifts down, and the removed one leaves the question with no correct
  /// option to point at (which the validator then asks for, rather than storing
  /// an index that now names the wrong answer).
  void _removeOption(int index) {
    if (_draft.options.length <= QuestionDraft.minOptions) return;
    setState(() {
      _optionControllers.removeAt(index).dispose();
      final options = List<String>.of(_draft.options)..removeAt(index);
      final current = _draft.correctOption;
      int? correct = current;
      if (current != null) {
        if (current == index) {
          correct = null;
        } else if (current > index) {
          correct = current - 1;
        }
      }
      _draft = _draft.copyWith(
        options: options,
        correctOption: correct,
        clearCorrectOption: correct == null,
      );
    });
  }

  /// The draft as the fields stand right now: the controllers are where a
  /// keystroke lives until they are folded in, so this is what both the
  /// validator and the save use.
  QuestionDraft get _folded => _draft.copyWith(
        questionText: _questionController.text,
        options: _draft.questionType.isMultipleChoice
            ? [for (final controller in _optionControllers) controller.text]
            : const <String>[],
        correctTextAnswer: _answerController.text,
        points: double.tryParse(_pointsController.text.trim()) ?? 0,
      );

  /// The marks field is text, so a typo ("two") has to be answered here rather
  /// than quietly becoming 0 — which would be a question worth nothing, stored
  /// without complaint.
  String? get _pointsProblem =>
      double.tryParse(_pointsController.text.trim()) == null
          ? 'Marks must be a number.'
          : null;

  /// The reason the form cannot be saved yet, or null when it can.
  String? get _problem => _pointsProblem ?? _folded.problem;

  void _setTrueFalse(bool value) {
    final word = value ? 'true' : 'false';
    _answerController.text = word;
    setState(() => _draft = _draft.copyWith(correctTextAnswer: word));
  }

  void _selectCorrectOption(int index) =>
      setState(() => _draft = _draft.copyWith(correctOption: index));

  void _save() {
    final problem = _problem;
    if (problem != null) {
      setState(() {
        _draft = _folded;
        _showProblem = true;
      });
      return;
    }
    Navigator.pop(context, _folded);
  }

  /// A hint per shape, so an empty editor still says what belongs in it.
  String get _questionHint => switch (_draft.questionType) {
        QuestionType.multipleChoice =>
          'Which data structure processes elements in FIFO order?',
        QuestionType.trueFalse =>
          'A pull request may be merged before its checks pass.',
        QuestionType.fillInTheBlank => 'What does the acronym HTTP stand for?',
        QuestionType.subjective =>
          'Describe how you would review a change that touches authentication.',
      };

  Widget _typePicker() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final type in QuestionType.values)
            ChoiceChip(
              key: Key('question-type-${type.dbValue}'),
              label: Text(type.label),
              selected: _draft.questionType == type,
              onSelected: (_) => _setType(type),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.existing == null;
    final problem = _showProblem ? _problem : null;

    return AlertDialog(
      key: const Key('question-editor'),
      title: Text(isNew ? 'Add a question' : 'Edit question'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pick the shape, then fill in what it needs. '
                '${_draft.questionType.markingLabel}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              _typePicker(),
              const SizedBox(height: 16),
              TextField(
                key: const Key('question-text'),
                controller: _questionController,
                autofocus: isNew,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onChanged: _updateQuestionText,
                decoration: InputDecoration(
                  labelText: _draft.questionType.isSubjective
                      ? 'Essay prompt'
                      : 'Question',
                  hintText: _questionHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ..._answerFields(theme),
              const SizedBox(height: 16),
              TextField(
                key: const Key('question-points'),
                controller: _pointsController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                // Digits and a decimal point only: the validator's "Marks must
                // be a number." is the backstop, not the first line of defence.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Marks',
                  helperText: 'What the question is worth.',
                  prefixIcon: Icon(Icons.star_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              if (problem != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        problem,
                        key: const Key('question-problem'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('question-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('question-save'),
          onPressed: _save,
          child: Text(isNew ? 'Add question' : 'Save changes'),
        ),
      ],
    );
  }

  /// The fields particular to the selected shape. Everything common to all four
  /// (the wording and the marks) is rendered by [build].
  List<Widget> _answerFields(ThemeData theme) => switch (_draft.questionType) {
        QuestionType.multipleChoice => _multipleChoiceFields(theme),
        QuestionType.trueFalse => _trueFalseFields(theme),
        QuestionType.fillInTheBlank => _fillInTheBlankFields(theme),
        QuestionType.subjective => _subjectiveFields(theme),
      };

  List<Widget> _multipleChoiceFields(ThemeData theme) => [
        Text(
          'Options — mark the correct one',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _optionControllers.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('question-option-$i'),
                    controller: _optionControllers[i],
                    onChanged: (value) => _updateOption(i, value),
                    decoration: InputDecoration(
                      labelText: 'Option ${String.fromCharCode(65 + i)}',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  key: Key('question-option-correct-$i'),
                  tooltip: _draft.correctOption == i
                      ? 'The correct answer'
                      : 'Mark as the correct answer',
                  onPressed: () => _selectCorrectOption(i),
                  color: _draft.correctOption == i
                      ? theme.colorScheme.primary
                      : null,
                  icon: Icon(
                    _draft.correctOption == i
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                ),
                if (_optionControllers.length > QuestionDraft.minOptions)
                  IconButton(
                    key: Key('question-remove-option-$i'),
                    tooltip: 'Remove this option',
                    onPressed: () => _removeOption(i),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('question-add-option'),
            onPressed: _optionControllers.length >= QuestionDraft.maxOptions
                ? null
                : _addOption,
            icon: const Icon(Icons.add),
            label: const Text('Add option'),
          ),
        ),
      ];

  List<Widget> _trueFalseFields(ThemeData theme) => [
        Text('The statement is', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                key: const Key('question-answer-true'),
                label: const Text('True'),
                selected: _draft.isTrue,
                onSelected: (_) => _setTrueFalse(true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                key: const Key('question-answer-false'),
                label: const Text('False'),
                selected:
                    _answerController.text.trim().toLowerCase() == 'false',
                onSelected: (_) => _setTrueFalse(false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Graded automatically: the student taps True or False, and the word '
          'they tapped is compared with yours, case-insensitively.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ];

  List<Widget> _fillInTheBlankFields(ThemeData theme) => [
        TextField(
          key: const Key('question-answer-text'),
          controller: _answerController,
          textCapitalization: TextCapitalization.none,
          onChanged: _updateAnswer,
          decoration: const InputDecoration(
            labelText: 'Accepted answer',
            helperText:
                'Graded trimmed and case-insensitively: “  http ” counts for '
                '“HTTP”.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'One accepted wording per question. A wording that should also be '
          'accepted in another spelling is a multiple-choice question.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ];

  List<Widget> _subjectiveFields(ThemeData theme) => [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.grading_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No answer key, because a mark is a judgement. The attempt '
                  'waits in Marks until every essay on the paper has one, and '
                  'nothing scores an essay automatically.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ];
}
