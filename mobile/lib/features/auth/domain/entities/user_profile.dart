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
  /// Since the reset hardening wave
  /// (`supabase/migrations/20261103090600_submissions_delete_supervisor.sql`) the
  /// server splits that action in two: the **DELETE** of the attempt is
  /// `is_exam_supervisor() or owns_exam(exam_id)` - an administrator or supervisor
  /// on any sitting, a lecturer only on the papers they wrote - while the snapshot
  /// **purge** and the **audit row** still ask `is_attempt_resetter()`. This getter
  /// is the *role* half of that answer, which is why the monitor also asks the
  /// paper's own `created_by` before offering the control
  /// (`SupervisorDashboardPage.canResetThisExam`).
  ///
  /// It is still asked in exactly one place: the role gate, the admin dashboard,
  /// the lecturer console and the live monitor must not be able to disagree about
  /// whether an account may reset an attempt at all.
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
