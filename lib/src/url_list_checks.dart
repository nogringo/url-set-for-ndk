/// When the relays were last asked for one list of an account, and whether
/// they held it. The list itself stays in NDK's cache.
class UrlListCheck {
  /// Account whose list was asked for.
  final String pubkey;

  /// Event kind of the list: 10002, 10050, 10013 or 10063.
  final int kind;

  /// When a relay last answered the query.
  final DateTime checkedAt;

  /// Whether the list existed then.
  final bool found;

  /// Creates a check.
  const UrlListCheck({
    required this.pubkey,
    required this.kind,
    required this.checkedAt,
    required this.found,
  });

  /// Serializes the check for storage.
  Map<String, Object?> toMap() => {
    'pubkey': pubkey,
    'kind': kind,
    'checkedAt': checkedAt.millisecondsSinceEpoch,
    'found': found,
  };

  /// Inverse of [toMap].
  factory UrlListCheck.fromMap(Map map) => UrlListCheck(
    pubkey: map['pubkey'] as String,
    kind: map['kind'] as int,
    checkedAt: DateTime.fromMillisecondsSinceEpoch(
      map['checkedAt'] as int,
      isUtc: true,
    ),
    found: map['found'] as bool,
  );
}

/// Where `ndkUrlListFn` keeps its [UrlListCheck]s, one per pubkey and kind.
/// Implement it on the database the app already has to keep them across
/// restarts. [UrlListCheck.toMap] gives a JSON-compatible record.
abstract interface class UrlListCheckStore {
  /// The check of the [kind] list of [pubkey], or null if it never ran.
  Future<UrlListCheck?> read(String pubkey, int kind);

  /// Replaces the check of the same pubkey and kind.
  Future<void> write(UrlListCheck check);
}

/// A [UrlListCheckStore] that lives as long as the process.
class MemoryUrlListCheckStore implements UrlListCheckStore {
  final _checks = <String, UrlListCheck>{};

  @override
  Future<UrlListCheck?> read(String pubkey, int kind) async =>
      _checks['$kind|$pubkey'];

  @override
  Future<void> write(UrlListCheck check) async =>
      _checks['${check.kind}|${check.pubkey}'] = check;
}
