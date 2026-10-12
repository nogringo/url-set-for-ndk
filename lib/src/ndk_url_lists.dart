import 'dart:convert';

import 'package:ndk/entities.dart' show Nip65, ReadWriteMarker;
import 'package:ndk/ndk.dart';

import 'indexer_relays.dart';
import 'url_set.dart';

const _kPrivateRelays = 10013;

/// Builds a [UrlListFn] that reads kind 10002, 10050, 10013 and 10063 through
/// [ndk], cache included, so a list seen before resolves offline.
///
/// Without an event, the lookup is `notFound` when at least one relay sent
/// EOSE, and `unavailable` otherwise. The lists are queried on
/// [discoveryRelays], not on NDK's bootstrap relays, plus the pubkey's write
/// relays for a list published there. [queryTimeout] bounds each query and
/// defaults to NDK's query timeout.
///
/// A private relay list is decrypted through `ndk.decryptedEventPayloads`, so
/// a given list event is decrypted once and read from NDK's cache afterwards,
/// account or not. Otherwise the signer of the matching account in
/// `ndk.accounts` decrypts it, with no timeout. A missing account or a failed
/// decryption is `unavailable`, so the lookup is retried.
UrlListFn ndkUrlListFn(
  Ndk ndk, {
  Iterable<String> discoveryRelays = defaultIndexerRelays,
  Duration? queryTimeout,
}) {
  return (pubkey, kind, outboxRelays) async {
    final response = ndk.requests.query(
      filter: Filter(authors: [pubkey], kinds: [_eventKind(kind)]),
      explicitRelays: {...outboxRelays, ...discoveryRelays},
      timeout: queryTimeout,
    );
    final events = await response.future;
    if (events.isNotEmpty) {
      final latest = events.reduce((a, b) => b.createdAt > a.createdAt ? b : a);
      if (kind != UrlListKind.private) {
        return UrlListLookup.found(urlsOfList(latest, kind));
      }
      return _decryptPrivateRelays(ndk, pubkey, latest);
    }
    final outcomes = await response.relayOutcomesDone;
    if (outcomes.values.any((o) => o.status == RelayRequestStatus.eose)) {
      return const UrlListLookup.notFound();
    }
    return UrlListLookup.unavailable(
      outcomes.isEmpty
          ? 'no relay reached'
          : outcomes.entries.map((e) => '${e.key}: ${e.value}').join(', '),
    );
  };
}

int _eventKind(UrlListKind kind) => switch (kind) {
  UrlListKind.dm => Nip51List.kDmRelays,
  UrlListKind.private => _kPrivateRelays,
  UrlListKind.blossom => Blossom.kBlossomUserServerList,
  UrlListKind.outbox || UrlListKind.inbox || UrlListKind.nip65 => Nip65.kKind,
};

Future<UrlListLookup> _decryptPrivateRelays(
  Ndk ndk,
  String owner,
  Nip01Event event,
) async {
  if (event.content.isEmpty) return const UrlListLookup.found([]);
  final payloads = ndk.decryptedEventPayloads;
  final cached = await payloads.loadCachedPlaintext(
    eventId: event.id,
    viewerPubKey: owner,
  );
  if (cached != null) return UrlListLookup.found(urlsOfPrivateTags(cached));

  final account = ndk.accounts.accounts[owner];
  if (account == null) {
    return UrlListLookup.unavailable('account $owner is not in NDK');
  }
  final String? plaintext;
  try {
    plaintext = await payloads.loadOrDecrypt(
      event: event,
      viewerPubKey: owner,
      scheme: DecryptedPayloadScheme.nip44,
      decrypt: () => account.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: event.pubKey,
      ),
    );
  } catch (e) {
    return UrlListLookup.unavailable('private relay list not decrypted: $e');
  }
  if (plaintext == null) {
    return const UrlListLookup.unavailable('private relay list not decrypted');
  }
  return UrlListLookup.found(urlsOfPrivateTags(plaintext));
}

/// Relay URLs of the decrypted private tags of a kind 10013. Anything that is
/// not a JSON list of tags yields no relay.
List<String> urlsOfPrivateTags(String plaintext) {
  final Object? tags;
  try {
    tags = jsonDecode(plaintext);
  } on FormatException {
    return const [];
  }
  if (tags is! List) return const [];
  return [
    for (final tag in tags)
      if (tag is List &&
          tag.length >= 2 &&
          tag[0] == 'relay' &&
          tag[1] is String)
        tag[1] as String,
  ];
}

/// URLs of a public list [event] for [kind]. A private list must be decrypted
/// first, see [urlsOfPrivateTags].
List<String> urlsOfList(Nip01Event event, UrlListKind kind) {
  List<String> tagValues(String name) => [
    for (final tag in event.tags)
      if (tag.length >= 2 && tag[0] == name) tag[1],
  ];
  switch (kind) {
    case UrlListKind.dm:
      return tagValues(Nip51List.kRelay);
    case UrlListKind.blossom:
      return tagValues('server');
    case UrlListKind.private:
      throw ArgumentError.value(kind, 'kind', 'is encrypted');
    case UrlListKind.nip65:
      return Nip65.fromEvent(event).relays.keys.toList();
    case UrlListKind.outbox:
    case UrlListKind.inbox:
      final wanted = kind == UrlListKind.outbox
          ? (ReadWriteMarker m) => m.isWrite
          : (ReadWriteMarker m) => m.isRead;
      return [
        for (final entry in Nip65.fromEvent(event).relays.entries)
          if (wanted(entry.value)) entry.key,
      ];
  }
}
