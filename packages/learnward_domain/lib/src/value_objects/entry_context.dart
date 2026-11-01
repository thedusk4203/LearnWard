/// Non-authoritative audit and provenance context for assessment entry.
///
/// NOTE: This context is purely for audit trails and NEVER acts as an authorization boundary.
enum EntryContext {
  adult('adult'),
  sharedChild('shared_child'),
  pairedChild('paired_child');

  const EntryContext(this.value);

  final String value;

  static EntryContext parse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final ctx in values) {
      if (ctx.value == normalized) {
        return ctx;
      }
    }
    throw ArgumentError.value(raw, 'entry_context', 'Unknown entry context');
  }
}
