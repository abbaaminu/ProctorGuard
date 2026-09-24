import 'package:equatable/equatable.dart';

/// `public.users.role` — the only two values the check constraint in
/// `supabase/schema.sql` allows.
enum UserRole {
  student,
  supervisor;

  /// Parses the database value.
  ///
  /// Throws rather than defaulting: an unrecognised role must surface as the
  /// gate's error state, not silently drop a supervisor into the student portal
  /// (or the other way round).
  static UserRole fromDb(String value) => switch (value) {
        'student' => UserRole.student,
        'supervisor' => UserRole.supervisor,
        _ => throw ArgumentError.value(value, 'users.role', 'Unknown role'),
      };

  String get dbValue => name;
}

/// The `public.users` row for the authenticated account (1:1 with
/// `auth.users`).
class UserProfile extends Equatable {
  const UserProfile({
    required this.id,
    required this.role,
    required this.name,
    required this.email,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) => UserProfile(
        id: map['id'] as String,
        role: UserRole.fromDb(map['role'] as String),
        name: map['name'] as String? ?? '',
        email: map['email'] as String? ?? '',
      );

  final String id;
  final UserRole role;
  final String name;
  final String email;

  bool get isStudent => role == UserRole.student;

  /// "Aisha Bello", falling back to the address when the row has no name.
  String get displayName => name.trim().isEmpty ? email : name;

  @override
  List<Object?> get props => [id, role, name, email];
}
