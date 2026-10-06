import 'package:equatable/equatable.dart';

/// `public.profiles.role` — the four values of the `public.user_role` enum in
/// `supabase/schema.sql`.
///
/// Declared in the enum's own order (most privileged first), which is also the
/// order the admin dashboard's role picker offers.
enum UserRole {
  admin,
  lecturer,
  supervisor,
  student;

  /// Parses the database value.
  ///
  /// Throws rather than defaulting: an unrecognised role must surface as the
  /// gate's error state, not silently drop somebody into the student portal
  /// (or the other way round).
  static UserRole fromDb(String value) => switch (value) {
        'admin' => UserRole.admin,
        'lecturer' => UserRole.lecturer,
        'supervisor' => UserRole.supervisor,
        'student' => UserRole.student,
        _ => throw ArgumentError.value(value, 'profiles.role', 'Unknown role'),
      };

  /// Title-case name for pickers and labels.
  String get label => switch (this) {
        UserRole.admin => 'Admin',
        UserRole.lecturer => 'Lecturer',
        UserRole.supervisor => 'Supervisor',
        UserRole.student => 'Student',
      };

  String get dbValue => name;

  /// Who may clear a student's attempt and its proctoring evidence — the roles
  /// `is_attempt_resetter()` names in `supabase/schema.sql`
  /// (`role in ('admin', 'supervisor', 'lecturer')`).
  ///
  /// The **policies** are the authority (`submissions_delete_supervisor`, plus
  /// the Storage delete policy that lets the console drop the snapshots those
  /// rows pointed at, plus the audit insert). This getter is the same question
  /// asked by the screens that render the control, and it is asked in exactly
  /// *one* place for that reason: the role gate, the admin dashboard, the
  /// lecturer console and the live monitor must not be able to disagree about
  /// whether an account may reset an attempt.
  /// `schema_contract_test.dart` reads the role list back out of `schema.sql`
  /// and the migrations and fails if the two drift apart.
  ///
  /// Lecturers are in the tier because they are the paper's author: they already
  /// read every attempt through `is_staff()`, and the reset is the repair for the
  /// mistakes only they can see. They are deliberately *not* in
  /// `is_exam_supervisor()`, which is the narrower tier that may rewrite an
  /// attempt in place (a status change or an after-the-fact re-grade).
  bool get canResetAttempts =>
      this == UserRole.admin ||
      this == UserRole.supervisor ||
      this == UserRole.lecturer;
}

/// The `public.profiles` row for the authenticated account (1:1 with
/// `auth.users`).
class UserProfile extends Equatable {
  const UserProfile({
    required this.id,
    required this.role,
    required this.fullName,
    required this.email,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) => UserProfile(
        id: map['id'] as String,
        role: UserRole.fromDb(map['role'] as String),
        fullName: map['full_name'] as String? ?? '',
        email: map['email'] as String? ?? '',
      );

  final String id;
  final UserRole role;

  /// `profiles.full_name` — the column an earlier revision called `name`.
  final String fullName;

  final String email;

  bool get isStudent => role == UserRole.student;

  /// Account management: mirrors `is_admin()` in `supabase/schema.sql`.
  bool get isAdmin => role == UserRole.admin;

  /// Staff tier: mirrors `is_staff()` — admin, lecturer or supervisor. These are
  /// the roles that may read every profile row and open a live monitor.
  bool get isStaff => role != UserRole.student;

  /// "Aisha Bello", falling back to the address when the row has no name.
  String get displayName => fullName.trim().isEmpty ? email : fullName;

  @override
  List<Object?> get props => [id, role, fullName, email];
}
