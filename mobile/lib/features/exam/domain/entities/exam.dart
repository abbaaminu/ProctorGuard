import 'package:equatable/equatable.dart';

class Exam extends Equatable {
  final String id;
  final String title;
  final String createdBy;
  final int durationMinutes;
  final bool isPublished;

  const Exam({
    required this.id,
    required this.title,
    required this.createdBy,
    required this.durationMinutes,
    required this.isPublished,
  });

  factory Exam.fromMap(Map<String, dynamic> map) => Exam(
        id: map['id'] as String,
        title: map['title'] as String,
        createdBy: map['created_by'] as String,
        durationMinutes: map['duration_minutes'] as int,
        isPublished: map['is_published'] as bool,
      );

  @override
  List<Object?> get props => [id, title, createdBy, durationMinutes, isPublished];
}
