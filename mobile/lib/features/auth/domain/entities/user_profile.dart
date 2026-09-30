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
