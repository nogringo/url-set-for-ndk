import 'dart:async';
import 'dart:convert';

import 'package:ndk/entities.dart' show Nip65;
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';
import 'package:test/test.dart';
import 'package:url_set_for_ndk/src/ndk_url_lists.dart';
import 'package:url_set_for_ndk/url_set_for_ndk.dart';

class FakeUrlLists {
  final Map<String, UrlListLookup> answers = {};
  final List<String> calls = [];
  final Map<String, List<String>> outboxRelaysSeen = {};
  Completer<void>? gate;

  void set(String pubkey, UrlListKind kind, UrlListLookup answer) =>
      answers['${kind.name}|$pubkey'] = answer;

  UrlListFn get fn => (pubkey, kind, outboxRelays) async {
    final id = '${kind.name}|$pubkey';
    calls.add(id);
    outboxRelaysSeen[id] = outboxRelays;
    await gate?.future;
    return answers[id] ?? const UrlListLookup.unavailable('offline');
  };
}

class CountingSigner extends Bip340EventSigner {
  int decryptions = 0;

  CountingSigner(KeyPair keys)
    : super(privateKey: keys.privateKey, publicKey: keys.publicKey);

  @override
  Future<String?> decryptNip44({
    required String ciphertext,
    required String senderPubKey,
  }) {
    decryptions++;
    return super.decryptNip44(
      ciphertext: ciphertext,
      senderPubKey: senderPubKey,
    );
  }
}

List<String>? resolvedUrls(UrlResolution r) =>
    r is UrlsResolved ? r.urls : null;

void main() {
  group('UrlSet serialization', () {
    test('round-trips a nested set', () {
      const set = UrlSet.fallback([
        UrlSet.union([
          UrlSet.outbox('p1'),
          UrlSet.nip65('p5'),
          UrlSet.inbox('p2'),
          UrlSet.inbox('p3'),
          UrlSet.explicit(['wss://a']),
        ]),
        UrlSet.dm('p4'),
        UrlSet.private('p6'),
        UrlSet.blossom('p7'),
      ]);
      expect(UrlSet.fromMap(set.toMap()).toMap(), set.toMap());
    });

    test('reads maps stored by RelaySet', () {
      final set = UrlSet.fromMap({
        'type': 'union',
        'sets': [
          {
            'type': 'explicit',
            'relays': ['wss://a'],
          },
          {'type': 'outbox', 'pubkey': 'p1'},
          {
            'type': 'inbox',
            'pubkeys': ['p2', 'p3'],
          },
          {'type': 'dm', 'pubkeys': <String>[]},
        ],
      });
      final sets = (set as UnionUrls).sets;
      expect((sets[0] as ExplicitUrls).urls, ['wss://a']);
      expect((sets[1] as OutboxUrls).pubkey, 'p1');
      expect((sets[2] as UnionUrls).sets.map((s) => (s as InboxUrls).pubkey), [
        'p2',
        'p3',
      ]);
      expect((sets[3] as UnionUrls).sets, isEmpty);
      expect(set.needsLookup, isTrue);
      expect(sets[3].needsLookup, isFalse);
    });

    test('rejects an unknown type', () {
      expect(() => UrlSet.fromMap({'type': 'nope'}), throwsFormatException);
    });

    test('only lookups need a list function', () {
      expect(const UrlSet.explicit(['wss://a']).needsLookup, isFalse);
      expect(
        const UrlSet.union([
          UrlSet.explicit(['wss://a']),
          UrlSet.union([]),
        ]).needsLookup,
        isFalse,
      );
      expect(
        const UrlSet.fallback([
          UrlSet.explicit([]),
          UrlSet.outbox('p'),
        ]).needsLookup,
        isTrue,
      );
    });

    test('kinds lists every leaf kind', () {
      expect(const UrlSet.explicit(['wss://a']).kinds, isEmpty);
      expect(
        const UrlSet.fallback([
          UrlSet.blossom('p'),
          UrlSet.union([
            UrlSet.dm('p'),
            UrlSet.explicit(['wss://a']),
          ]),
        ]).kinds,
        {UrlListKind.blossom, UrlListKind.dm},
      );
    });
  });

  group('resolveUrlSet', () {
    test('union merges every list and treats notFound as empty', () async {
      final lists = FakeUrlLists()
        ..set('p1', UrlListKind.outbox, const UrlListLookup.found(['wss://w']))
        ..set('p2', UrlListKind.inbox, const UrlListLookup.found(['wss://r']))
        ..set('p3', UrlListKind.inbox, const UrlListLookup.notFound());
      final r = await resolveUrlSet(
        const UrlSet.union([
          UrlSet.outbox('p1'),
          UrlSet.inbox('p2'),
          UrlSet.inbox('p3'),
          UrlSet.explicit(['wss://x']),
        ]),
        lists.fn,
      );
      expect(resolvedUrls(r), ['wss://w', 'wss://r', 'wss://x']);
    });

    test('union is unavailable if any lookup is', () async {
      final lists = FakeUrlLists()
        ..set('p1', UrlListKind.outbox, const UrlListLookup.found(['wss://w']));
      final r = await resolveUrlSet(
        const UrlSet.union([UrlSet.outbox('p1'), UrlSet.dm('p2')]),
        lists.fn,
      );
      expect(r, isA<UrlsUnavailable>());
      expect((r as UrlsUnavailable).reason, contains('dm list of p2'));
    });

    test('nip65 looks up every relay of the list', () async {
      final lists = FakeUrlLists()
        ..set(
          'p',
          UrlListKind.nip65,
          const UrlListLookup.found(['wss://r', 'wss://w']),
        );
      final r = await resolveUrlSet(const UrlSet.nip65('p'), lists.fn);
      expect(resolvedUrls(r), ['wss://r', 'wss://w']);
      expect(lists.calls, ['nip65|p']);
    });

    test('looks up DM relays on the NIP-65 write relays', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.outbox, const UrlListLookup.found(['wss://w']))
        ..set('p', UrlListKind.dm, const UrlListLookup.found(['wss://dm']));
      final r = await resolveUrlSet(const UrlSet.dm('p'), lists.fn);
      expect(resolvedUrls(r), ['wss://dm']);
      expect(lists.calls, ['outbox|p', 'dm|p']);
      expect(lists.outboxRelaysSeen['outbox|p'], isEmpty);
      expect(lists.outboxRelaysSeen['dm|p'], ['wss://w']);
    });

    test(
      'looks up DM relays without write relays when NIP-65 is not found',
      () async {
        final lists = FakeUrlLists()
          ..set('p', UrlListKind.outbox, const UrlListLookup.notFound())
          ..set('p', UrlListKind.dm, const UrlListLookup.found(['wss://dm']));
        final r = await resolveUrlSet(const UrlSet.dm('p'), lists.fn);
        expect(resolvedUrls(r), ['wss://dm']);
        expect(lists.outboxRelaysSeen['dm|p'], isEmpty);
      },
    );

    test('looks up private relays on the NIP-65 write relays', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.outbox, const UrlListLookup.found(['wss://w']))
        ..set('p', UrlListKind.private, const UrlListLookup.found(['wss://s']));
      final r = await resolveUrlSet(const UrlSet.private('p'), lists.fn);
      expect(resolvedUrls(r), ['wss://s']);
      expect(lists.calls, ['outbox|p', 'private|p']);
      expect(lists.outboxRelaysSeen['private|p'], ['wss://w']);
    });

    test('looks up Blossom servers on the NIP-65 write relays', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.outbox, const UrlListLookup.found(['wss://w']))
        ..set(
          'p',
          UrlListKind.blossom,
          const UrlListLookup.found(['https://cdn.example']),
        );
      final r = await resolveUrlSet(const UrlSet.blossom('p'), lists.fn);
      expect(resolvedUrls(r), ['https://cdn.example']);
      expect(lists.calls, ['outbox|p', 'blossom|p']);
      expect(lists.outboxRelaysSeen['blossom|p'], ['wss://w']);
    });

    test('DM relays are unavailable while NIP-65 is', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.dm, const UrlListLookup.found(['wss://dm']));
      final r = await resolveUrlSet(const UrlSet.dm('p'), lists.fn);
      expect(r, isA<UrlsUnavailable>());
      expect((r as UrlsUnavailable).reason, contains('NIP-65'));
      expect(lists.calls, ['outbox|p']);
    });

    test('shares the NIP-65 lookup between outbox and DM sets', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.outbox, const UrlListLookup.found(['wss://w']))
        ..set('p', UrlListKind.dm, const UrlListLookup.found(['wss://dm']));
      final r = await resolveUrlSet(
        const UrlSet.union([UrlSet.outbox('p'), UrlSet.dm('p')]),
        lists.fn,
      );
      expect(resolvedUrls(r), ['wss://w', 'wss://dm']);
      expect(lists.calls, ['outbox|p', 'dm|p']);
    });

    test('fallback skips empty and notFound sets', () async {
      final lists = FakeUrlLists()
        ..set('p1', UrlListKind.outbox, const UrlListLookup.notFound())
        ..set('p2', UrlListKind.outbox, const UrlListLookup.found([]))
        ..set('p3', UrlListKind.outbox, const UrlListLookup.found(['wss://c']));
      final r = await resolveUrlSet(
        const UrlSet.fallback([
          UrlSet.outbox('p1'),
          UrlSet.outbox('p2'),
          UrlSet.outbox('p3'),
          UrlSet.outbox('p4'),
        ]),
        lists.fn,
      );
      expect(resolvedUrls(r), ['wss://c']);
      expect(lists.calls, isNot(contains('outbox|p4')));
    });

    test('fallback to defaults when there is no Blossom list', () async {
      final lists = FakeUrlLists()
        ..set('p', UrlListKind.outbox, const UrlListLookup.notFound())
        ..set('p', UrlListKind.blossom, const UrlListLookup.notFound());
      final r = await resolveUrlSet(
        const UrlSet.fallback([
          UrlSet.blossom('p'),
          UrlSet.explicit(['https://default.example']),
        ]),
        lists.fn,
      );
      expect(resolvedUrls(r), ['https://default.example']);
    });

    test(
      'fallback stops on an unavailable set instead of falling through',
      () async {
        final lists = FakeUrlLists();
        final r = await resolveUrlSet(
          const UrlSet.fallback([
            UrlSet.outbox('p1'),
            UrlSet.explicit(['wss://local']),
          ]),
          lists.fn,
        );
        expect(r, isA<UrlsUnavailable>());
      },
    );

    test('looks up each pubkey and kind once', () async {
      final lists = FakeUrlLists()
        ..set('p1', UrlListKind.outbox, const UrlListLookup.found(['wss://a']))
        ..set('p1', UrlListKind.inbox, const UrlListLookup.found(['wss://b']));
      await resolveUrlSet(
        const UrlSet.union([
          UrlSet.outbox('p1'),
          UrlSet.outbox('p1'),
          UrlSet.inbox('p1'),
          UrlSet.inbox('p1'),
        ]),
        lists.fn,
      );
      expect(lists.calls, ['outbox|p1', 'inbox|p1']);
    });
  });

  group('urlsOfList', () {
    test('splits NIP-65 markers into outbox and inbox', () {
      final event = Nip01Event(
        pubKey: 'a' * 64,
        kind: Nip65.kKind,
        tags: [
          ['r', 'wss://both'],
          ['r', 'wss://read', 'read'],
          ['r', 'wss://write', 'write'],
        ],
        content: '',
      );
      expect(
        urlsOfList(event, UrlListKind.outbox),
        unorderedEquals(['wss://both', 'wss://write']),
      );
      expect(
        urlsOfList(event, UrlListKind.inbox),
        unorderedEquals(['wss://both', 'wss://read']),
      );
      expect(
        urlsOfList(event, UrlListKind.nip65),
        unorderedEquals(['wss://both', 'wss://read', 'wss://write']),
      );
    });

    test('reads relay tags of a kind 10050', () {
      final event = Nip01Event(
        pubKey: 'a' * 64,
        kind: Nip51List.kDmRelays,
        tags: [
          ['relay', 'wss://dm1'],
          ['r', 'wss://ignored'],
          ['relay', 'wss://dm2'],
        ],
        content: '',
      );
      expect(urlsOfList(event, UrlListKind.dm), ['wss://dm1', 'wss://dm2']);
    });

    test('reads server tags of a kind 10063 in order', () {
      final event = Nip01Event(
        pubKey: 'a' * 64,
        kind: Blossom.kBlossomUserServerList,
        tags: [
          ['server', 'https://first.example'],
          ['relay', 'wss://ignored'],
          ['server'],
          ['server', 'https://second.example'],
        ],
        content: '',
      );
      expect(urlsOfList(event, UrlListKind.blossom), [
        'https://first.example',
        'https://second.example',
      ]);
    });
  });

  group('urlsOfPrivateTags', () {
    test('keeps relay tags only', () {
      expect(
        urlsOfPrivateTags(
          jsonEncode([
            ['relay', 'wss://s1'],
            ['p', 'abc'],
            ['relay'],
            ['relay', 'wss://s2'],
          ]),
        ),
        ['wss://s1', 'wss://s2'],
      );
    });

    test('yields no relay for content that is not a tag list', () {
      expect(urlsOfPrivateTags('not json'), isEmpty);
      expect(urlsOfPrivateTags('{"relay": "wss://s"}'), isEmpty);
    });
  });

  group('ndkUrlListFn', () {
    late Ndk ndk;
    late MemCacheManager cache;
    late KeyPair keys;
    late Bip340EventSigner signer;

    setUp(() async {
      keys = Bip340.generatePrivateKey();
      cache = MemCacheManager();
      ndk = Ndk(
        NdkConfig(
          eventVerifier: Bip340EventVerifier(),
          cache: cache,
          bootstrapRelays: const ['ws://127.0.0.1:9'],
        ),
      );
      signer = Bip340EventSigner(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
      );
    });

    tearDown(() async {
      await ndk.destroy();
    });

    UrlListFn lookupFn() => ndkUrlListFn(
      ndk,
      discoveryRelays: const ['ws://127.0.0.1:9'],
      queryTimeout: const Duration(milliseconds: 200),
    );

    Future<void> savePrivateList() async {
      final content = await signer.encryptNip44(
        plaintext: jsonEncode([
          ['relay', 'wss://private.example'],
        ]),
        recipientPubKey: keys.publicKey,
      );
      await cache.saveEvent(
        await signer.sign(
          Nip01Event(
            pubKey: keys.publicKey,
            kind: 10013,
            tags: const [],
            content: content!,
          ),
        ),
      );
    }

    test('reads a cached Blossom server list', () async {
      await cache.saveEvent(
        await signer.sign(
          Nip01Event(
            pubKey: keys.publicKey,
            kind: Blossom.kBlossomUserServerList,
            tags: const [
              ['server', 'https://cdn.example'],
            ],
            content: '',
          ),
        ),
      );
      final lookup = await lookupFn()(
        keys.publicKey,
        UrlListKind.blossom,
        const [],
      );
      expect((lookup as UrlListFound).urls, ['https://cdn.example']);
    });

    test('is unavailable when no relay answers', () async {
      final lookup = await lookupFn()(
        keys.publicKey,
        UrlListKind.blossom,
        const [],
      );
      expect(lookup, isA<UrlListUnavailable>());
    });

    test('queries nothing with no relay to ask', () async {
      final lookup = await ndkUrlListFn(ndk, discoveryRelays: const [])(
        keys.publicKey,
        UrlListKind.dm,
        const [],
      );
      expect((lookup as UrlListUnavailable).reason, 'no relay to ask');
    });

    test('decrypts a private list with the account signer', () async {
      await savePrivateList();
      ndk.accounts.loginPrivateKey(
        pubkey: keys.publicKey,
        privkey: keys.privateKey!,
      );
      final lookup = await lookupFn()(
        keys.publicKey,
        UrlListKind.private,
        const [],
      );
      expect((lookup as UrlListFound).urls, ['wss://private.example']);
    });

    test('asks the signer once for the same list event', () async {
      await savePrivateList();
      final counting = CountingSigner(keys);
      ndk.accounts.loginExternalSigner(signer: counting);

      final lookups = await Future.wait([
        lookupFn()(keys.publicKey, UrlListKind.private, const []),
        lookupFn()(keys.publicKey, UrlListKind.private, const []),
      ]);
      ndk.accounts.removeAccount(pubkey: keys.publicKey);
      final afterRemoval = await lookupFn()(
        keys.publicKey,
        UrlListKind.private,
        const [],
      );

      for (final lookup in [...lookups, afterRemoval]) {
        expect((lookup as UrlListFound).urls, ['wss://private.example']);
      }
      expect(counting.decryptions, 1);
    });

    test(
      'a private list is unavailable while the account is not in NDK',
      () async {
        await savePrivateList();
        final lookup = await lookupFn()(
          keys.publicKey,
          UrlListKind.private,
          const [],
        );
        expect(lookup, isA<UrlListUnavailable>());
      },
    );
  });
}
