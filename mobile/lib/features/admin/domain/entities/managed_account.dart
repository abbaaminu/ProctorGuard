import 'package:equatable/equatable.dart';

import '../../../../core/utils/academic_catalog.dart';
import '../../../auth/domain/entities/user_profile.dart';

/// One `public.profiles` row as the admin dashboard lists it.
///
/// Deliberately separate from [UserProfile]: that entity describes *the signed-in
/// account* (it is what the role gate routes on), while this one is a row in the
/// roster an administrator manages, so it also carries `created_at` and the
/// academic labels an import fills in.
class ManagedAccount extends Equatable {
  const ManagedAccount({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    this.createdAt,
    this.faculty,
    this.department,
    this.level,
  });

  /// Tolerates a missing name/email/created_at (older rows, or a trimmed
  /// `select`) but not a missing id or an unknown role — [UserRole.fromDb]
  /// throws on the latter, which is the right failure: a role the app does not
  /// understand must not be rendered as if it were a familiar one.
  ///
  /// The academic labels are read leniently too: they arrive as null from a
  /// database that has not run `academic_targeting.sql` yet, which is exactly
  /// what "not narrowed" looks like.
  factory ManagedAccount.fromMap(Map<String, dynamic> map) {
    String? text(Object? value) {
      final raw = value is String ? value.trim() : '';
      return raw.isEmpty ? null : raw;
    }

    return ManagedAccount(
      id: map['id'] as String,
      email: map['email'] as String? ?? '',
      fullName: map['full_name'] as String? ?? '',
      role: UserRole.fromDb(map['role'] as String),
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      faculty: text(map['faculty']),
      department: text(map['department']),
      level: text(map['level']),
    );
  }

  final String id;
  final String email;
  final String fullName;
  final UserRole role;

  /// `profiles.created_at`, or null when the row (or the response) omits it.
  final DateTime? createdAt;

  /// `profiles.faculty / department / level` — what `exams_select` compares a
  /// published paper against. Null means "not stated", which matches papers that
  /// are not narrowed either.
  final String? faculty;
  final String? department;
  final String? level;

  bool get isAdmin => role == UserRole.admin;

  /// "Dr. Ada Nwosu", falling back to the address when the row has no name.
  String get displayName => fullName.trim().isEmpty ? email : fullName;

  /// "Computer Science · Science · 300 Level", or null for an unlabelled row —
  /// null rather than "All", because a blank column narrows nothing.
  String? get academicLabel =>
      AcademicCatalog.describe(faculty: faculty, department: department, level: level);

  @override
  List<Object?> get props =>
      [id, email, fullName, role, createdAt, faculty, department, level];
}

