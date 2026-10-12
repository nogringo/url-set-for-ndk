/// Which list of an account a [UrlSet] leaf reads.
enum UrlListKind {
  /// NIP-65 (kind 10002) relays marked for writing, or unmarked.
  outbox,

  /// NIP-65 (kind 10002) relays marked for reading, or unmarked.
  inbox,

  /// Every NIP-65 (kind 10002) relay, whatever its marker.
  nip65,

  /// NIP-17 DM relays (kind 10050).
  dm,

  /// NIP-37 private relays (kind 10013), encrypted to their owner.
  private,

  /// Blossom servers (kind 10063, BUD-03).
  blossom;

  /// Whether the list is published on the owner's NIP-65 write relays.
  bool get onOutbox => this == dm || this == private || this == blossom;
}

/// Looks up one list of [pubkey]. Called by a queue worker, never at enqueue
/// time, so it may hit the network.
///
/// [outboxRelays] are the NIP-65 write relays of [pubkey], where it publishes
/// its own lists. They are given when [UrlListKind.onOutbox] (empty when
/// [pubkey] has no NIP-65) and should be queried along with any discovery
/// relays. They are always empty for the NIP-65 kinds.
///
/// Resolution never times a lookup out: bound the network part, but let a
/// signer take as long as it needs.
typedef UrlListFn =
    Future<UrlListLookup> Function(
      String pubkey,
      UrlListKind kind,
      List<String> outboxRelays,
    );

/// Outcome of a single list lookup.
sealed class UrlListLookup {
  const UrlListLookup();

  /// The list exists. [urls] may be empty.
  const factory UrlListLookup.found(List<String> urls) = UrlListFound;

  /// Relays answered (EOSE) and none of them holds the list.
  const factory UrlListLookup.notFound() = UrlListNotFound;

  /// No relay answered, so whether the list exists is unknown.
  const factory UrlListLookup.unavailable([String? reason]) =
      UrlListUnavailable;
}

/// See [UrlListLookup.found].
final class UrlListFound extends UrlListLookup {
  /// URLs of the list, in the order the list gives them.
  final List<String> urls;

  /// Creates a found lookup.
  const UrlListFound(this.urls);
}

/// See [UrlListLookup.notFound].
final class UrlListNotFound extends UrlListLookup {
  /// Creates a not-found lookup.
  const UrlListNotFound();
}

/// See [UrlListLookup.unavailable].
final class UrlListUnavailable extends UrlListLookup {
  /// Why the lookup could not conclude, if known.
  final String? reason;

  /// Creates an unavailable lookup.
  const UrlListUnavailable([this.reason]);
}

/// Where something should be sent, described rather than listed so it can be
/// persisted offline and resolved later.
///
/// Leaves name relays or Blossom servers. A consumer accepts the leaves that
/// make sense for it: relays for events, Blossom servers for blobs.
sealed class UrlSet {
  const UrlSet();

  /// A fixed list of URLs. Needs no lookup.
  const factory UrlSet.explicit(List<String> urls) = ExplicitUrls;

  /// NIP-65 write relays of [pubkey].
  const factory UrlSet.outbox(String pubkey) = OutboxUrls;

  /// Every relay of the NIP-65 of [pubkey], read and write alike.
  const factory UrlSet.nip65(String pubkey) = Nip65Urls;

  /// NIP-65 read relays of [pubkey].
  const factory UrlSet.inbox(String pubkey) = InboxUrls;

  /// NIP-17 DM relays (kind 10050) of [pubkey]. Use this for gift wraps, not
  /// [UrlSet.inbox].
  const factory UrlSet.dm(String pubkey) = DmUrls;

  /// NIP-37 private relays (kind 10013) of [pubkey]. The list is encrypted to
  /// its owner, so [pubkey] must be an account able to decrypt it locally.
  const factory UrlSet.private(String pubkey) = PrivateUrls;

  /// Blossom servers (kind 10063) of [pubkey].
  const factory UrlSet.blossom(String pubkey) = BlossomUrls;

  /// Every URL of every set in [sets].
  const factory UrlSet.union(List<UrlSet> sets) = UnionUrls;

  /// The URLs of the first set in [sets] that resolves to a non-empty list.
  /// A list that is not found counts as empty. An unavailable one stops
  /// resolution, so an offline lookup never falls through to the next set.
  const factory UrlSet.fallback(List<UrlSet> sets) = FallbackUrls;

  /// Whether resolving this set calls a [UrlListFn].
  bool get needsLookup;

  /// Every list kind a leaf of this set reads. Empty for explicit URLs only.
  Set<UrlListKind> get kinds;

  /// Serializes the set for storage.
  Map<String, Object?> toMap();

  /// Inverse of [toMap].
  static UrlSet fromMap(Map map) {
    List<String> strings(String field) => (map[field] as List).cast<String>();
    List<UrlSet> sets() => (map['sets'] as List)
        .map((s) => UrlSet.fromMap(s as Map))
        .toList(growable: false);
    // RelaySet stored inbox and dm leaves with several pubkeys.
    UrlSet perPubkey(UrlSet Function(String pubkey) leaf) =>
        map.containsKey('pubkeys')
        ? UnionUrls([for (final p in strings('pubkeys')) leaf(p)])
        : leaf(map['pubkey'] as String);
    return switch (map['type']) {
      'explicit' => ExplicitUrls(strings('relays')),
      'outbox' => OutboxUrls(map['pubkey'] as String),
      'nip65' => Nip65Urls(map['pubkey'] as String),
      'inbox' => perPubkey(InboxUrls.new),
      'dm' => perPubkey(DmUrls.new),
      'private' => PrivateUrls(map['pubkey'] as String),
      'blossom' => BlossomUrls(map['pubkey'] as String),
      'union' => UnionUrls(sets()),
      'fallback' => FallbackUrls(sets()),
      final type => throw FormatException('unknown url set type: $type'),
    };
  }
}

/// See [UrlSet.explicit].
final class ExplicitUrls extends UrlSet {
  /// URLs.
  final List<String> urls;

  /// Creates an explicit set.
  const ExplicitUrls(this.urls);

  @override
  bool get needsLookup => false;

  @override
  Set<UrlListKind> get kinds => const {};

  // The `relays` key predates Blossom support: stored sets must keep loading.
  @override
  Map<String, Object?> toMap() => {'type': 'explicit', 'relays': urls};
}

/// A leaf that reads one list of one account.
sealed class _ListUrls extends UrlSet {
  /// Account whose list is read.
  final String pubkey;

  const _ListUrls(this.pubkey);

  UrlListKind get _kind;

  @override
  bool get needsLookup => true;

  @override
  Set<UrlListKind> get kinds => {_kind};

  @override
  Map<String, Object?> toMap() => {'type': _kind.name, 'pubkey': pubkey};
}

/// See [UrlSet.outbox].
final class OutboxUrls extends _ListUrls {
  /// Creates an outbox set.
  const OutboxUrls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.outbox;
}

/// See [UrlSet.nip65].
final class Nip65Urls extends _ListUrls {
  /// Creates a NIP-65 set.
  const Nip65Urls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.nip65;
}

/// See [UrlSet.inbox].
final class InboxUrls extends _ListUrls {
  /// Creates an inbox set.
  const InboxUrls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.inbox;
}

/// See [UrlSet.dm].
final class DmUrls extends _ListUrls {
  /// Creates a DM set.
  const DmUrls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.dm;
}

/// See [UrlSet.private].
final class PrivateUrls extends _ListUrls {
  /// Creates a private set.
  const PrivateUrls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.private;
}

/// See [UrlSet.blossom].
final class BlossomUrls extends _ListUrls {
  /// Creates a Blossom server set.
  const BlossomUrls(super.pubkey);

  @override
  UrlListKind get _kind => UrlListKind.blossom;
}

/// See [UrlSet.union].
final class UnionUrls extends UrlSet {
  /// Sets to merge.
  final List<UrlSet> sets;

  /// Creates a union set.
  const UnionUrls(this.sets);

  @override
  bool get needsLookup => sets.any((s) => s.needsLookup);

  @override
  Set<UrlListKind> get kinds => {for (final s in sets) ...s.kinds};

  @override
  Map<String, Object?> toMap() => {
    'type': 'union',
    'sets': [for (final s in sets) s.toMap()],
  };
}

/// See [UrlSet.fallback].
final class FallbackUrls extends UrlSet {
  /// Sets to try in order.
  final List<UrlSet> sets;

  /// Creates a fallback set.
  const FallbackUrls(this.sets);

  @override
  bool get needsLookup => sets.any((s) => s.needsLookup);

  @override
  Set<UrlListKind> get kinds => {for (final s in sets) ...s.kinds};

  @override
  Map<String, Object?> toMap() => {
    'type': 'fallback',
    'sets': [for (final s in sets) s.toMap()],
  };
}

/// Result of resolving a whole [UrlSet] tree.
sealed class UrlResolution {
  const UrlResolution();
}

/// Every lookup concluded. [urls] may be empty and is not deduplicated.
final class UrlsResolved extends UrlResolution {
  /// Resolved URLs, in tree order.
  final List<String> urls;

  /// Creates a resolved result.
  const UrlsResolved(this.urls);
}

/// At least one lookup that the result depends on was unavailable.
final class UrlsUnavailable extends UrlResolution {
  /// Every unavailable lookup, joined.
  final String reason;

  /// Creates an unavailable result.
  const UrlsUnavailable(this.reason);
}

/// Resolves [set] with [lookup]. Each `(pubkey, kind)` pair is looked up at
/// most once per call, and [UrlSet.fallback] never looks up the sets after
/// the first non-empty one. A list published on the owner's outbox (DM,
/// private, Blossom) is looked up after the NIP-65 of the same pubkey, on its
/// write relays.
Future<UrlResolution> resolveUrlSet(UrlSet set, UrlListFn lookup) {
  final memo = <String, Future<UrlListLookup>>{};
  return _resolve(
    set,
    (pubkey, kind, outboxRelays) => memo.putIfAbsent(
      '${kind.name}|$pubkey',
      () => lookup(pubkey, kind, outboxRelays),
    ),
  );
}

Future<UrlResolution> _resolve(UrlSet set, UrlListFn lookup) async {
  switch (set) {
    case ExplicitUrls(:final urls):
      return UrlsResolved(urls);
    case _ListUrls(:final pubkey, :final _kind):
      return _resolveList(pubkey, _kind, lookup);
    case UnionUrls(:final sets):
      return _merge(
        await Future.wait([for (final s in sets) _resolve(s, lookup)]),
      );
    case FallbackUrls(:final sets):
      for (final s in sets) {
        final resolution = await _resolve(s, lookup);
        if (resolution is UrlsUnavailable) return resolution;
        if ((resolution as UrlsResolved).urls.isNotEmpty) return resolution;
      }
      return const UrlsResolved([]);
  }
}

Future<UrlResolution> _resolveList(
  String pubkey,
  UrlListKind kind,
  UrlListFn lookup,
) async {
  UrlResolution unavailable(String? reason) => UrlsUnavailable(
    '${kind.name} list of $pubkey unavailable'
    '${reason == null ? '' : ': $reason'}',
  );

  var outboxRelays = const <String>[];
  if (kind.onOutbox) {
    switch (await lookup(pubkey, UrlListKind.outbox, const [])) {
      case UrlListFound(:final urls):
        outboxRelays = urls;
      case UrlListNotFound():
        break;
      case UrlListUnavailable(:final reason):
        return unavailable('NIP-65 ${reason ?? 'unavailable'}');
    }
  }

  return switch (await lookup(pubkey, kind, outboxRelays)) {
    UrlListFound(:final urls) => UrlsResolved(urls),
    UrlListNotFound() => const UrlsResolved([]),
    UrlListUnavailable(:final reason) => unavailable(reason),
  };
}

UrlResolution _merge(List<UrlResolution> parts) {
  final unavailable = parts.whereType<UrlsUnavailable>();
  if (unavailable.isNotEmpty) {
    return UrlsUnavailable(unavailable.map((u) => u.reason).join('; '));
  }
  return UrlsResolved([
    for (final part in parts.cast<UrlsResolved>()) ...part.urls,
  ]);
}
