# url_set_for_ndk

Relay and Blossom server sets for the [`ndk`](https://pub.dev/packages/ndk)
package, described rather than listed.

An offline-first queue often has to decide where something goes before it can
look anything up: "my write relays", "the DM relays of these recipients", "my
Blossom servers, or these defaults if I have none". A `UrlSet` stores that
intent as a small tree that serializes to JSON, so it can sit in a queue
record and be resolved later, when the network is back.

This package holds the type and its resolver. It is shared by
[`broadcast_queue_shim_for_ndk`](https://pub.dev/packages/broadcast_queue_shim_for_ndk)
and
[`blossom_upload_queue_shim_for_ndk`](https://pub.dev/packages/blossom_upload_queue_shim_for_ndk).

## Install

```yaml
dependencies:
  url_set_for_ndk: ^0.2.1
  ndk: ^0.10.0-dev.7
```

## Sets

| Constructor | Resolves to |
|---|---|
| `UrlSet.explicit(urls)` | `urls`, with no lookup |
| `UrlSet.outbox(pubkey)` | NIP-65 (kind 10002) write relays |
| `UrlSet.inbox(pubkey)` | NIP-65 read relays |
| `UrlSet.nip65(pubkey)` | every NIP-65 relay, read and write |
| `UrlSet.dm(pubkey)` | NIP-17 DM relays (kind 10050) |
| `UrlSet.private(pubkey)` | NIP-37 private relays (kind 10013), decrypted by their owner |
| `UrlSet.blossom(pubkey)` | BUD-03 Blossom servers (kind 10063) |
| `UrlSet.union(sets)` | every URL of every set |
| `UrlSet.fallback(sets)` | the first set that resolves to a non-empty list |

Every leaf reads the list of one account. Combine several with `union`:

```dart
UrlSet.union([for (final p in recipients) UrlSet.dm(p)])
```

Relays and Blossom servers share one type. A consumer checks `set.kinds` and
rejects the leaves it cannot use: a broadcast queue has no use for Blossom
servers, and a blob upload queue none for DM relays.

## Resolving

```dart
import 'package:ndk/ndk.dart';
import 'package:url_set_for_ndk/url_set_for_ndk.dart';

final lookup = ndkUrlListFn(ndk);

final resolution = await resolveUrlSet(
  UrlSet.fallback([
    UrlSet.blossom(pubkey),
    UrlSet.explicit(['https://blossom.primal.net']),
  ]),
  lookup,
);

switch (resolution) {
  case UrlsResolved(:final urls):
    print('send to $urls');
  case UrlsUnavailable(:final reason):
    print('try again later: $reason');
}
```

Every lookup ends in one of three states:

- `found`: the list exists. It may be empty.
- `notFound`: at least one relay answered (EOSE) and none holds the list.
- `unavailable`: no relay answered, so nothing is known.

Resolution follows from that:

- A union is unavailable as soon as one of its parts is.
- A fallback treats `notFound` as empty and moves on, but stops on
  `unavailable`. An offline device never falls through to the defaults while
  the real list might exist.
- Each `(pubkey, kind)` pair is looked up once per resolution.
- DM, private and Blossom lists are published on their owner's NIP-65 write
  relays, so their NIP-65 is looked up first and its write relays are queried
  along with the discovery relays.

`UrlsResolved.urls` keeps tree order and is not deduplicated or normalized:
that is up to the consumer.

## The NDK lookup

`ndkUrlListFn(ndk, discoveryRelays: ..., queryTimeout: ...)` reads the lists
through `ndk.requests.query`, NDK's cache included, so a list seen before
resolves offline. `discoveryRelays` defaults to `defaultIndexerRelays`. With
no discovery relay and no write relay to ask, nothing is queried: NDK's
bootstrap relays are never used.

`auth` is the NIP-42 policy of every query, NDK's default when omitted. Pass
`AuthPolicy.never()` to look up someone else's lists without attributing the
lookup to the logged account.

A kind 10013 is encrypted to its owner. It is decrypted once through
`ndk.decryptedEventPayloads` and read from NDK's cache afterwards. Until then
the owner's account must be in `ndk.accounts`, otherwise the lookup is
`unavailable` and will be retried.

### Remembering when a list was checked

Without more, every lookup goes to the relays. Pass a `UrlListCheckStore` and
`ndkUrlListFn` keeps the date of every answered query, per pubkey and kind:

```dart
final lookup = ndkUrlListFn(
  ndk,
  checks: MemoryUrlListCheckStore(),
  maxAge: const Duration(hours: 1),
);
```

- A list checked less than `maxAge` ago is read from NDK's cache, with no
  query. That holds for a missing list too: an account without a DM list is
  not asked again every time.
- Past `maxAge` the relays are asked again. If none answers, the last known
  state still holds, so a list goes on resolving offline once seen. Only a
  list never checked is `unavailable`.
- A list published since, by the app itself, is in NDK's cache and wins
  whatever the date.
- A list found but since gone from NDK's cache is asked again.

`offline: true` never queries the relays and answers from NDK's cache and the
checks alone, whatever their age. That is the lookup for a question that must
stay local.

`MemoryUrlListCheckStore` forgets everything on restart. To keep the checks,
implement `UrlListCheckStore` on your database: `UrlListCheck.toMap()` gives a
JSON-compatible record.

To resolve without NDK, or in tests, pass any `UrlListFn`:

```dart
Future<UrlListLookup> lookup(
  String pubkey,
  UrlListKind kind,
  List<String> outboxRelays,
) async => const UrlListLookup.notFound();
```

## Storage

`toMap()` gives a JSON-compatible map and `UrlSet.fromMap()` reads it back.
The format is the one `RelaySet` used in `broadcast_queue_shim_for_ndk`
0.7.0, so queues stored by that version keep loading.

## License

MIT
