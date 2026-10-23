import 'dart:convert';

import 'package:csv/csv.dart';

import '../../exam/domain/entities/question.dart';
import '../domain/entities/authored_question.dart';
import '../domain/entities/question_pack.dart';

/// Reads the question file a lecturer uploads into the same [QuestionDraft] the
/// manual editor produces.
///
/// Parsing lives here, in `data/`, because it is a *format* boundary: the widget
/// above it knows about files and progress, the repository below it knows about
/// HTTP, and neither should know that a CSV separates cells with commas or that
/// a JSON answer may be `true` rather than `"true"`. The result is the domain's
/// [QuestionPackParse], so what a bad file means is described once, in one type,
/// instead of in a screen full of strings.
///
/// Two formats are accepted, decided by the first character of the file rather
/// than by its extension — an export saved as `.txt` still reads:
///
///  * **JSON** — an array of objects, or `{"questions": [ ... ]}`. Each object
///    names its `type`, its `question`, and its answer key (`answer`, or
///    `correct_option` for a multiple-choice index).
///  * **CSV** — one question per row under the header in [templateHeader]. The
///    options cell holds the choices separated by `|`.
///
/// Every entry is validated with [QuestionDraft.problem] before it is handed
/// back, which is the same rule the editor applies and mirrors the database's
/// `questions_answer_key_shape`. A draft that fails that check is reported as a
/// [QuestionPackProblem] and the rest of the file still loads: one malformed row
/// in the middle of forty should cost that row, not the paper.
///
/// Header names are matched through [_aliases], because spreadsheets rename
/// columns freely ("Question Text", "Marks") and a file refused over a capital
/// letter would be a support ticket rather than a safeguard.
class QuestionPackParser {
  const QuestionPackParser._();

  /// The header this parser accepts, in the order the template writes it.
  static const List<String> columns = <String>[
    'type',
    'question',
    'options',
    'correct_answer',
    'points',
  ];

  /// "type,question,options,correct_answer,points" — what the upload card shows
  /// as its template, and what a rejected header is compared against.
  static String get templateHeader => columns.join(',');

  /// Entries accepted from one file. A paper of 200 questions is already
  /// unusual; the cap only stops a mis-picked 50 000-line export from becoming
  /// 50 000 sequential inserts before anyone notices.
  static const int maxQuestions = 200;

  /// The separator inside the CSV's `options` cell. A pipe rather than a comma
  /// because the cell is already inside a comma-separated row, and a comma there
  /// would need quoting in every spreadsheet that writes the file by hand.
  static const String optionSeparator = '|';

  /// Every spelling of a column this parser recognises, keyed by the name it
  /// means. Compared through [_keyOf], so case, spaces, hyphens and underscores
  /// are all the same spelling here ("Question Text" = "question_text").
  static const Map<String, List<String>> _aliases = <String, List<String>>{
    'type': <String>['type', 'questiontype', 'kind', 'shape'],
    'question': <String>[
      'question',
      'questiontext',
      'text',
      'prompt',
      'statement',
    ],
    'options': <String>['options', 'choices', 'option'],
    'correct_answer': <String>[
      'correctanswer',
      'answer',
      'correcttextanswer',
      'correctoption',
      'key',
      'answerkey',
      'correct',
    ],
    'points': <String>['points', 'marks', 'mark', 'score', 'weight'],
  };

  /// The words the type cell may hold for each shape, after [_keyOf].
  static const Map<QuestionType, List<String>> _typeNames =
      <QuestionType, List<String>>{
    QuestionType.multipleChoice: <String>[
      'multiplechoice',
      'multichoice',
      'mcq',
      'choice',
      'choices',
      'multiple',
    ],
    QuestionType.trueFalse: <String>[
      'truefalse',
      'trueorfalse',
      'boolean',
      'tf',
    ],
    QuestionType.fillInTheBlank: <String>[
      'fillintheblank',
      'fillinblank',
      'fillblank',
      'fib',
      'blank',
    ],
    QuestionType.subjective: <String>[
      'subjective',
      'essay',
      'longanswer',
      'free',
    ],
  };

  /// The four types, in the words a refusal offers back.
  static String get typeNames =>
      QuestionType.values.map((type) => type.dbValue).join(', ');

  /// Parses [text], the decoded contents of the chosen file.
  ///
  /// Never throws: a file that cannot be read at all comes back as
  /// [QuestionPackParse.fileError], and an entry that cannot be used comes back
  /// in [QuestionPackParse.problems] so the rest of the paper still uploads.
  static QuestionPackParse parse(String text) {
    final source = _stripBom(text);
    if (source.trim().isEmpty) {
      return QuestionPackParse(
        fileError: 'This file is empty. It needs questions in it — a JSON array '
            'or a CSV with the header $templateHeader',
      );
    }

    // Content, not extension: `[` and `{` are the only starts JSON allows, and a
    // CSV whose first cell begins with either could not be read as one anyway.
    final first = source.trimLeft()[0];
    return first == '[' || first == '{'
        ? _parseJson(source)
        : _parseCsv(source);
  }

  /// Excel exports UTF-8 with a byte-order mark; left in place it would turn the
  /// first header cell into "\uFEFFtype" and lose the column.
  static String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;

  /// Trims [raw] and reads a blank as *absent* (null), which is what "this cell
  /// was not filled in" means throughout the parser.
  static String? _clean(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// "Question_Text " → "questiontext", the form [_aliases] is keyed on and the
  /// form [_typeNames] compares with.
  static String _keyOf(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  // ---------------------------------------------------------------- JSON ----

  /// The JSON branch: an array of question objects, or one wrapped in a key
  /// (`questions`, `items`, `data`) so a tool that exports an envelope still
  /// reads.
  static QuestionPackParse _parseJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const QuestionPackParse(
        fileError: 'This file could not be read as JSON. Save the questions as '
            'an array of objects ([{ "type": … }]), or export them as CSV and '
            'upload that.',
      );
    }

    final Object? list = switch (decoded) {
      final List<dynamic> value => value,
      final Map<String, dynamic> value => _firstList(value),
      _ => null,
    };
    if (list is! List) {
      return const QuestionPackParse(
        fileError: 'This file is not a list of questions. It should be a JSON '
            'array of question objects, or an object holding one under '
            '"questions".',
      );
    }

    final drafts = <QuestionDraft>[];
    final problems = <QuestionPackProblem>[];

    for (var at = 0; at < list.length; at++) {
      // The position in the array, counted from 1 — what an author can count to
      // in whatever editor opened the file.
      final line = at + 1;
      final entry = list[at];
      if (entry is! Map) {
        problems.add(
          QuestionPackProblem(
            line: line,
            message: 'This entry is not a question object.',
          ),
        );
        continue;
      }

      final fields = <String, Object?>{
        for (final field in entry.entries)
          _keyOf(field.key.toString()): field.value,
      };
      final text = _clean(_value(fields, _aliases['question']!)?.toString());
      if (text == null) {
        problems.add(
          QuestionPackProblem(
            line: line,
            message: 'This entry has no question text.',
          ),
        );
        continue;
      }

      final rawType = _value(fields, _aliases['type']!)?.toString();
      final type = _typeOf(rawType);
      if (type == null) {
        problems.add(
          QuestionPackProblem(
            line: line,
            message: _typeMessage(rawType),
          ),
        );
        continue;
      }

      if (drafts.length >= maxQuestions) return _tooMany();

      final options = _optionsOf(
        _value(fields, _aliases['options']!),
        line,
        problems,
      );
      if (options == null) continue;

      final draft = _draftFrom(
        type: type,
        text: text,
        options: options,
        answer: _value(fields, _aliases['correct_answer']!),
        points: _pointsOf(
          _value(fields, _aliases['points']!),
          line,
          problems,
        ),
        line: line,
        problems: problems,
      );
      if (draft != null) drafts.add(draft);
    }

    return QuestionPackParse(drafts: drafts, problems: problems);
  }

  /// The first of `questions` / `items` / `data` that holds a list.
  static Object? _firstList(Map<String, dynamic> value) {
    for (final key in const <String>['questions', 'items', 'data']) {
      final candidate = value[key];
      if (candidate is List) return candidate;
    }
    return null;
  }

  /// The first alias in [aliases] the object actually carries, or null.
  ///
  /// `containsKey` rather than a null check: an entry that writes
  /// `"answer": null` is not the same as one that leaves the key out, and the
  /// shape checks below are what turn that difference into a sentence.
  static Object? _value(Map<String, Object?> fields, List<String> aliases) {
    for (final alias in aliases) {
      final key = _keyOf(alias);
      if (fields.containsKey(key)) return fields[key];
    }
    return null;
  }


  // ----------------------------------------------------------------- CSV ----

  /// The CSV branch: one question per row under a header this parser
  /// recognises, with the options cell split on [optionSeparator].
  static QuestionPackParse _parseCsv(String source) {
    final List<List<dynamic>> table;
    try {
      table = Csv(
        // Keep blank lines: they are counted so a problem can name the line the
        // spreadsheet shows. (A quoted cell containing a newline still shifts
        // the count — the message names the question too where it can.)
        skipEmptyLines: false,
      ).decode(source);
    } on Exception {
      return const QuestionPackParse(
        fileError: 'This file could not be read as CSV. In your spreadsheet use '
            '"Save as" → CSV, then choose it again.',
      );
    }

    if (table.isEmpty) {
      return QuestionPackParse(
        fileError: 'This file is empty. It needs a header row: '
            '$templateHeader',
      );
    }

    final header = _readHeader(table.first);
    if (header.error != null) return QuestionPackParse(fileError: header.error);

    if (!header.has('question') || !header.has('type')) {
      final missing = <String>[
        if (!header.has('question')) 'question',
        if (!header.has('type')) 'type',
      ];
      return QuestionPackParse(
        fileError: 'The header is missing ${missing.join(' and ')}. The first '
            'line should read: $templateHeader',
      );
    }

    final drafts = <QuestionDraft>[];
    final problems = <QuestionPackProblem>[];

    for (var index = 1; index < table.length; index++) {
      final line = index + 1;
      final cells = table[index];
      String? cell(String column) {
        final at = header.index[column];
        if (at == null || at >= cells.length) return null;
        return _clean(cells[at]?.toString());
      }

      // Blank lines (a trailing newline, a spacer row) are not problems.
      final isBlank =
          cells.every((value) => _clean(value?.toString()) == null);
      if (isBlank) continue;

      if (drafts.length >= maxQuestions) return _tooMany();

      final rawType = cell('type');
      final type = _typeOf(rawType);
      if (type == null) {
        problems.add(
          QuestionPackProblem(
            line: line,
            message: _typeMessage(rawType),
          ),
        );
        continue;
      }

      final text = cell('question');
      if (text == null) {
        problems.add(
          QuestionPackProblem(
            line: line,
            message: 'There is no question on this line.',
          ),
        );
        continue;
      }

      final options = _optionsOf(cell('options'), line, problems);
      if (options == null) continue;

      final draft = _draftFrom(
        type: type,
        text: text,
        options: options,
        answer: cell('correct_answer'),
        points: _pointsOf(cell('points'), line, problems),
        line: line,
        problems: problems,
      );
      if (draft != null) drafts.add(draft);
    }

    return QuestionPackParse(drafts: drafts, problems: problems);
  }

  /// Where each known column sits in the header row.
  static _Header _readHeader(List<dynamic> row) {
    final index = <String, int>{};
    for (var at = 0; at < row.length; at++) {
      final name = _keyOf(row[at]?.toString() ?? '');
      if (name.isEmpty) continue;
      for (final entry in _aliases.entries) {
        final aliases = entry.value.map(_keyOf);
        if (aliases.contains(name) && !index.containsKey(entry.key)) {
          index[entry.key] = at;
          break;
        }
      }
    }

    if (index.isEmpty) {
      return const _Header(
        index: <String, int>{},
        error: 'The first line must be the column names: '
            'type,question,options,correct_answer,points',
      );
    }
    return _Header(index: index);
  }


  // ------------------------------------------------------- shared reading ----

  /// The shape a type cell names, or null when it names none.
  static QuestionType? _typeOf(String? raw) {
    final key = _keyOf(raw ?? '');
    if (key.isEmpty) return null;
    for (final entry in _typeNames.entries) {
      if (entry.value.contains(key)) return entry.key;
    }
    return null;
  }

  /// What to say about a type cell the parser could not read: an absent cell and
  /// an unknown word are different mistakes and get different sentences.
  static String _typeMessage(String? raw) {
    final value = _clean(raw);
    if (value == null) return 'There is no question type on this line.';
    return '"$value" is not a question type. Use one of $typeNames.';
  }

  /// The option list an entry carries, or null when it could not be read (in
  /// which case the reason is already in [problems]).
  ///
  /// JSON hands over a list; a CSV cell is one string split on
  /// [optionSeparator]. A blank between two separators is refused rather than
  /// dropped: `A||C` is a half-written option, and storing it as two options
  /// would silently shift which one the key points at.
  static List<String>? _optionsOf(
    Object? raw,
    int line,
    List<QuestionPackProblem> problems,
  ) {
    if (raw == null) return const <String>[];

    final List<String> options;
    if (raw is List) {
      options = raw.map((option) => option?.toString().trim() ?? '').toList();
    } else if (raw is String) {
      options = raw.split(optionSeparator).map((part) => part.trim()).toList();
    } else {
      problems.add(
        QuestionPackProblem(
          line: line,
          message: 'The options could not be read. Use a list, or a single cell '
              'with the options separated by $optionSeparator.',
        ),
      );
      return null;
    }

    if (options.any((option) => option.isEmpty)) {
      problems.add(
        QuestionPackProblem(
          line: line,
          message: 'One of the options is empty. Remove the empty '
              '$optionSeparator between options.',
        ),
      );
      return null;
    }

    return options;
  }

  /// The marks an entry is worth, or null when the cell is not a number (in
  /// which case the reason is already in [problems]).
  ///
  /// An absent cell is one mark — the column's own default in the database —
  /// rather than zero, so a file that leaves marks out still produces a paper
  /// that can be scored.
  static double? _pointsOf(
    Object? raw,
    int line,
    List<QuestionPackProblem> problems,
  ) {
    if (raw == null) return 1;
    if (raw is num) return raw.toDouble();

    final value = double.tryParse(raw.toString().trim());
    if (value != null) return value;

    problems.add(
      QuestionPackProblem(
        line: line,
        message: '"${raw.toString().trim()}" is not a number of marks.',
      ),
    );
    return null;
  }

  /// The answer key as a multiple-choice option index: a JSON number, or the
  /// option's own text (compared case-insensitively) — the spelling a lecturer
  /// writing a file by hand is most likely to use.
  static int? _optionIndex(Object? raw, List<String> options) {
    if (raw is num) return raw.toInt();

    final value = _clean(raw?.toString());
    if (value == null) return null;

    for (var at = 0; at < options.length; at++) {
      if (options[at].toLowerCase() == value.toLowerCase()) return at;
    }
    return int.tryParse(value);
  }

  /// 'true' / 'false' for a true/false answer — a JSON boolean, or either word
  /// in any casing. Anything else is refused rather than guessed at, because the
  /// stored key is what `submit_exam()` compares the student against.
  static String? _trueFalseOf(Object? raw) {
    if (raw is bool) return raw ? 'true' : 'false';
    final value = _clean(raw?.toString())?.toLowerCase();
    if (value == 'true') return 'true';
    if (value == 'false') return 'false';
    return null;
  }



  /// The draft every shape is built from, or null when it cannot be stored (in
  /// which case the reason is already in [problems]).
  ///
  /// The key goes on the field the type actually grades against and nowhere
  /// else — the same rule as [QuestionDraft.toRow], which is what keeps an
  /// uploaded row from carrying a key its shape cannot have.
  static QuestionDraft? _draftFrom({
    required QuestionType type,
    required String text,
    required List<String> options,
    required Object? answer,
    required double? points,
    required int line,
    required List<QuestionPackProblem> problems,
  }) {
    // Already reported, and a draft with no marks cannot be built.
    if (points == null) return null;

    int? correctOption;
    var correctTextAnswer = '';

    switch (type) {
      case QuestionType.multipleChoice:
        if (options.length < QuestionDraft.minOptions) {
          problems.add(
            QuestionPackProblem(
              line: line,
              message: 'A multiple-choice question needs at least '
                  '${QuestionDraft.minOptions} options.',
            ),
          );
          return null;
        }
        final index = _optionIndex(answer, options);
        if (index == null) {
          problems.add(
            QuestionPackProblem(
              line: line,
              message: 'There is no correct option for this multiple-choice '
                  'question. Name one of the options, or its position '
                  '(0 for the first).',
            ),
          );
          return null;
        }
        if (index < 0 || index >= options.length) {
          problems.add(
            QuestionPackProblem(
              line: line,
              message: 'Option $index is not in the list of '
                  '${options.length} options — use 0 for the first.',
            ),
          );
          return null;
        }
        correctOption = index;
      case QuestionType.trueFalse:
        final value = _trueFalseOf(answer);
        if (value == null) {
          problems.add(
            QuestionPackProblem(
              line: line,
              message:
                  'A true/false question needs an answer of true or false.',
            ),
          );
          return null;
        }
        correctTextAnswer = value;
      case QuestionType.fillInTheBlank:
        final value = _clean(answer?.toString());
        if (value == null) {
          problems.add(
            QuestionPackProblem(
              line: line,
              message: 'There is no accepted answer for this fill-in-the-blank '
                  'question.',
            ),
          );
          return null;
        }
        correctTextAnswer = value;
      case QuestionType.subjective:
        // Nothing to ask for: the absence of a key is the whole shape, and any
        // key the row happens to carry is dropped by `toRow`.
        break;
    }

    final draft = QuestionDraft(
      questionType: type,
      questionText: text,
      // Options are only a multiple-choice thing; the other shapes store an
      // empty list, so a stray options cell on a true/false row is ignored
      // rather than stored as a choice that cannot be tapped.
      options: type.isMultipleChoice ? options : const <String>[],
      correctOption: correctOption,
      correctTextAnswer: correctTextAnswer,
      points: points,
    );

    // The editor's own rules, applied to the file: identical messages whether
    // the question was typed or uploaded.
    final problem = draft.problem;
    if (problem != null) {
      problems.add(QuestionPackProblem(line: line, message: problem));
      return null;
    }
    return draft;
  }

  /// The refusal for a file with more entries than [maxQuestions].
  static QuestionPackParse _tooMany() => QuestionPackParse(
        fileError: 'This file has more than $maxQuestions questions. Split it '
            'into smaller files and upload them one after another.',
      );
}

/// A parsed header row: the column positions found, or why none were.
class _Header {
  const _Header({required this.index, this.error});

  final Map<String, int> index;
  final String? error;

  bool has(String column) => index.containsKey(column);
}

