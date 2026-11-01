/// Stable canonical subject identity for longitudinal progress and mastery tracking.
enum SubjectKey {
  math('math', 'Mathematics'),
  english('english', 'English'),
  literature('literature', 'Literature'),
  science('science', 'Science'),
  other('other', 'Other');

  const SubjectKey(this.value, this.defaultLabel);

  final String value;
  final String defaultLabel;

  /// Human-friendly display label (e.g. 'Mathematics', 'English').
  String get displayLabel => defaultLabel;

  static SubjectKey parse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final key in values) {
      if (key.value == normalized) {
        return key;
      }
    }
    throw ArgumentError.value(raw, 'subject_key', 'Unknown subject key');
  }
}
