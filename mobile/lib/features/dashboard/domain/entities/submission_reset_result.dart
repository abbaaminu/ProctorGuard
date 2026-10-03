class SubmissionResetResult {
  const SubmissionResetResult({
    required this.incidents,
    required this.snapshots,
    this.storageWarning,
  });

  final int incidents;
  final int snapshots;
  final String? storageWarning;
}
