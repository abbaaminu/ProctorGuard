import 'dart:convert';

import 'package:file_picker/file_picker.dart';

/// A roster file the administrator chose, already read off disk.
///
/// The contents arrive as a string rather than bytes so a widget (and a test)
/// only has to deal with the file's text; the decoding lives in
/// [pickRosterFile]. Shared by the two file-driven cards — creating a class and
/// correcting its labels — because "a file the administrator chose" is the same
/// thing to both of them.
class RosterFile {
  const RosterFile({required this.name, required this.contents});

  /// The file's name, shown so the administrator can see which list is on
  /// screen — "students.csv" is not a guarantee about its contents.
  final String name;

  final String contents;
}

/// Picks the roster file, or null when the administrator closed the picker.
typedef RosterFilePicker = Future<RosterFile?> Function();

/// The platform picker, used when a card was not handed a [RosterFilePicker].
///
/// `file_picker` 12 returns a [PlatformFile] rather than a path, and its bytes
/// are read on demand — which is what makes this work on the web, where the
/// picker (rightly) hands out no path at all.
Future<RosterFile?> pickRosterFile({required String dialogTitle}) async {
  final file = await FilePicker.pickFile(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: const <String>['csv', 'txt'],
  );
  if (file == null) return null;

  return RosterFile(
    name: file.name,
    // Malformed input is replaced rather than thrown on: one stray byte in a
    // name should not hide the rest of the class from the parser, which reports
    // what it cannot use far more precisely.
    contents: utf8.decode(await file.readAsBytes(), allowMalformed: true),
  );
}
