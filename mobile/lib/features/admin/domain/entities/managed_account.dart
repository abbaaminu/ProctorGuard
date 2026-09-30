import 'package:equatable/equatable.dart';

import '../../../auth/domain/entities/user_profile.dart';

/// One `public.profiles` row as the admin dashboard lists it.
///
/// Deliberately separate from [UserProfile]: that entity describes *the signed-in
/// account* (it is what the role gate routes on), while this one is a row in the
/// roster an administrator manages, so it also carries `created_at`.
class ManagedAccount extends Equatable {
  const ManagedAccount({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    this.createdAt,
  });

  /// Tolerates a missing name/email/created_at (older rows, or a trimmed
  /// `select`) but not a missing id or an unknown role — [UserRole.fromDb]
  /// throws on the latter, which is the right failure: a role the app does not
  /// understand must not be rendered as if it were a familiar one.
  factory ManagedAccount.fromMap(Map<String, dynamic> map) => ManagedAccount(
        id: map['id'] as String,
        email: map['email'] as String? ?? '',
        fullName: map['full_name'] as String? ?? '',
        role: UserRole.fromDb(map['role'] as String),
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? ''),
      );

  final String id;
  final String email;
  final String fullName;
  final UserRole role;

  /// `profiles.created_at`, or null when the row (or the response) omits it.
  final DateTime? createdAt;

  bool get isAdmin => role == UserRole.admin;

  /// "Dr. Ada Nwosu", falling back to the address when the row has no name.
  String get displayName => fullName.trim().isEmpty ? email : fullName;

  @override
  List<Object?> get props => [id, email, fullName, role, createdAt];
}
