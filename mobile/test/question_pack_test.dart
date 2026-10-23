import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/authoring/data/question_pack_parser.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';

/// The question file parser, as a lecturer would meet it: what a well-formed file
/// becomes, and what a broken one is told.
///
/// The parse is a pure function of the file's text, so these run without a
/// widget, a picker, or a server. What matters is that the result is the *same*
/// `QuestionDraft` the editor produces — one shape check, one write path — and
/// that a bad entry costs that entry and not the paper.
void main() {
  /// One question of each shape, exactly as the upload card documents them.
  const jsonFile = '''
[
  {
    "type": "multiple_choice",
    "question": "Which process model delivers a working increment?",
    "options": ["Waterfall", "Scrum"],
    "answer": "Scrum",
    "points": 2
  },
  {
    "type": "true_false",
    "question": "A pull request may be merged before its checks pass.",
    "answer": false,
    "points": 1
  },
  {
    "type": "fill_in_the_blank",
    "question": "What is running the suite on every change called?",
    "answer": "Continuous integration"
  },
  {
    "type": "subjective",
    "question": "Describe how you would review a change to authentication.",
    "points": 5
  }
]
''';

  group('JSON files', () {
    test('read all four shapes into the drafts the editor would have made', () {
      final parse = QuestionPackParser.parse(jsonFile);

      expect(parse.fileError, isNull);
      expect(parse.problems, isEmpty);
      expect(parse.drafts, hasLength(4));

      final mcq = parse.drafts[0];
      expect(mcq.questionType, QuestionType.multipleChoice);
      expect(mcq.options, <String>['Waterfall', 'Scrum']);
      // Named by its text, which is the spelling a person writing a file uses.
      expect(mcq.correctOption, 1);
      expect(mcq.correctTextAnswer, isEmpty);
      expect(mcq.points, 2);

      final trueFalse = parse.drafts[1];
      expect(trueFalse.questionType, QuestionType.trueFalse);
      expect(trueFalse.correctTextAnswer, 'false');
      expect(trueFalse.correctOption, isNull);
      expect(trueFalse.options, isEmpty);

      final blank = parse.drafts[2];
      expect(blank.questionType, QuestionType.fillInTheBlank);
      expect(blank.correctTextAnswer, 'Continuous integration');
      // The column's own default in the database, so a file that omits marks is
      // still a paper that can be scored.
      expect(blank.points, 1);

      final essay = parse.drafts[3];
      expect(essay.questionType, QuestionType.subjective);
      expect(essay.correctTextAnswer, isEmpty);
      expect(essay.correctOption, isNull);
      expect(essay.points, 5);
    });

    test('produce drafts that pass the shape check and the row it writes', () {
      final parse = QuestionPackParser.parse(jsonFile);

      for (final draft in parse.drafts) {
        expect(draft.problem, isNull);
      }

      final essayRow = parse.drafts[3].toRow();
      // No key on an essay: the shape cannot carry one, and `toRow` is what stops
      // an uploaded row from trying.
      expect(essayRow['correct_option'], isNull);
      expect(essayRow['correct_text_answer'], isNull);
      expect(essayRow['question_type'], 'subjective');

      final mcqRow = parse.drafts[0].toRow();
      expect(mcqRow['correct_option'], 1);
      expect(mcqRow['options'], <String>['Waterfall', 'Scrum']);
      expect(mcqRow['correct_text_answer'], isNull);
    });

    test('read an array wrapped in an envelope as well as a bare one', () {
      final parse = QuestionPackParser.parse(
        '{"questions": [{"type": "true_false", '
        '"question": "CI runs on every push.", "answer": true}]}',
      );

      expect(parse.fileError, isNull);
      expect(parse.drafts.single.questionType, QuestionType.trueFalse);
      expect(parse.drafts.single.correctTextAnswer, 'true');
    });

    test('report each unusable entry by its position, and keep the rest', () {
      final parse = QuestionPackParser.parse('''
[
  {"type": "essay", "question": "Explain the trade-offs of code review.", "points": 4},
  {"type": "matching", "question": "Not a shape this app has."},
  {"type": "multiple_choice", "question": "No key at all.", "options": ["A", "B"]},
  {"type": "multiple_choice", "question": "Key past the end.", "options": ["A", "B"], "answer": 2},
  {"type": "true_false", "question": "Yes and no are not answers.", "answer": "yes"},
  {"type": "fill_in_the_blank", "question": "The blanks stay empty."},
  {"type": "multiple_choice", "question": "Which one is the key?", "options": ["A", "B"], "answer": "b"},
  "not an object"
]
''');

      // Every position is counted from 1, so the author can count to it.
      expect(
        parse.problems.map((problem) => problem.line).toList(),
        <int>[2, 3, 4, 5, 6, 8],
      );
      expect(
        parse.problems[0].message,
        '"matching" is not a question type. Use one of multiple_choice, '
        'true_false, fill_in_the_blank, subjective.',
      );
      expect(parse.problems[1].message, contains('no correct option'));
      expect(
        parse.problems[2].message,
        contains('not in the list of 2 options'),
      );
      expect(
        parse.problems[3].message,
        'A true/false question needs an answer of true or false.',
      );
      expect(parse.problems[4].message, contains('fill-in-the-blank'));
      expect(parse.problems[5].message, contains('not a question object'));

      // The two usable entries still arrive: one malformed row in the middle of a
      // file costs that row, not the paper.
      expect(parse.drafts.map((draft) => draft.points).toList(), <double>[4, 1]);
      expect(parse.drafts[1].correctOption, 1); // "b" matched case-insensitively
    });

    test('refuse the whole file only when it is not a list of questions', () {
      final malformed = QuestionPackParser.parse('[{"type": "essay",]');
      expect(malformed.drafts, isEmpty);
      expect(malformed.fileError, contains('could not be read as JSON'));

      final notAList =
          QuestionPackParser.parse('{"paper": {"title": "GES301"}}');
      expect(notAList.drafts, isEmpty);
      expect(notAList.fileError, contains('not a list of questions'));
    });
  });

  group('CSV files', () {
    /// The header the upload card offers, plus a row that renames two columns —
    /// which is what a spreadsheet does to a template the moment it is opened.
    const csvFile = 'Type,Question Text,Choices,Answer,Marks\n'
        'multiple_choice,Which process model delivers a working increment?,'
        'Waterfall|Scrum,Scrum,2\n'
        'true_false,A pull request may be merged before its checks pass.,,false,1\n'
        '\n'
        'fill_in_the_blank,What is running the suite on every change called?,,'
        'Continuous integration,,\n'
        'subjective,Describe how you would review a change to authentication.,'
        ',,5\n'
        'matching,Not a shape this app has.,,,1\n';

    test('read a row per question, with the options split on a pipe', () {
      final parse = QuestionPackParser.parse(csvFile);

      expect(parse.fileError, isNull);
      expect(parse.drafts, hasLength(4));

      final mcq = parse.drafts[0];
      expect(mcq.questionType, QuestionType.multipleChoice);
      expect(mcq.options, <String>['Waterfall', 'Scrum']);
      expect(mcq.correctOption, 1); // named by its text
      expect(mcq.points, 2);

      expect(parse.drafts[1].correctTextAnswer, 'false');
      expect(parse.drafts[2].correctTextAnswer, 'Continuous integration');
      // A blank marks cell is one mark, not zero.
      expect(parse.drafts[2].points, 1);
      expect(parse.drafts[3].questionType, QuestionType.subjective);
      expect(parse.drafts[3].points, 5);

      // The blank line was not a question, and the unknown shape was one — named
      // by the line the spreadsheet shows, counting the header.
      expect(parse.problems, hasLength(1));
      expect(parse.problems.single.line, 7);
      expect(parse.problems.single.message, contains('"matching"'));
    });

    test('read a renamed question column, because a spreadsheet renames it',
        () {
      final parse = QuestionPackParser.parse(
        'type,prompt,choices,answer\nmultiple_choice,Which one?,A|B,0\n',
      );

      expect(parse.fileError, isNull);
      expect(parse.drafts.single.questionText, 'Which one?');
      expect(parse.drafts.single.options, <String>['A', 'B']);
      expect(parse.drafts.single.correctOption, 0);
    });

    test('refuse a header with no question column, and name the one missing',
        () {
      final parse = QuestionPackParser.parse(
        'type,answer\nmultiple_choice,0\n',
      );

      expect(parse.drafts, isEmpty);
      expect(parse.fileError, contains('missing question'));
      expect(parse.fileError, contains('type,question,options,correct_answer,'
          'points'));
    });

    test('refuse a file with no header at all', () {
      final parse = QuestionPackParser.parse('just,some,words\nand,more\n');

      expect(parse.drafts, isEmpty);
      expect(parse.fileError, contains('must be the column names'));
    });
  });

  group('what a file cannot be', () {
    test('an empty file is refused whole, naming the header it needs', () {
      final parse = QuestionPackParser.parse(' \n\n ');

      expect(parse.drafts, isEmpty);
      expect(parse.problems, isEmpty);
      expect(parse.fileError, contains('This file is empty'));
      expect(parse.fileError, contains(QuestionPackParser.templateHeader));
    });

    test('a UTF-8 byte-order mark does not cost the first column', () {
      // Excel writes one; left in place the first header cell would be
      // "\uFEFFtype" and the file would be refused as missing a type column.
      final parse = QuestionPackParser.parse(
        '\uFEFFtype,question,answer\n'
        'true_false,Checks run before merge.,true\n',
      );

      expect(parse.fileError, isNull);
      expect(parse.drafts.single.questionType, QuestionType.trueFalse);
    });

    test('a hole in the option list is refused rather than closed up', () {
      final parse = QuestionPackParser.parse(
        'type,question,options,answer\n'
        'multiple_choice,Which one?,A||C,A\n',
      );

      expect(parse.drafts, isEmpty);
      expect(
        parse.problems.single.message,
        contains('One of the options is empty'),
      );
    });

    test('a file past the batch cap is refused whole, before anything is sent',
        () {
      final source = StringBuffer('[');
      for (var at = 0; at <= QuestionPackParser.maxQuestions; at++) {
        if (at > 0) source.write(',');
        source.write('{"type": "essay", "question": "Question $at"}');
      }
      source.write(']');

      final parse = QuestionPackParser.parse(source.toString());

      expect(parse.drafts, isEmpty);
      expect(
        parse.fileError,
        contains('more than ${QuestionPackParser.maxQuestions} questions'),
      );
    });
  });
}

