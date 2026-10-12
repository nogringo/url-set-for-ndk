import 'dart:convert';
import 'dart:io';

import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';
import 'package:test/test.dart';
import 'package:url_set_for_ndk/url_set_for_ndk.dart';

/// Serves its [events] to any REQ by author and kind, then sends EOSE.
class TinyRelay {
  final List<Nip01Event> events = [];
  int requests = 0;
  late final HttpServer _server;

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.transform(WebSocketTransformer()).listen((socket) {
      socket.listen((data) {
        final message = jsonDecode(data as String) as List;
        if (message.first != 'REQ') return;
        requests++;
        final subId = message[1] as String;
        for (final filter in message.skip(2).cast<Map>()) {
          for (final event in events) {
            if ((filter['authors'] as List).contains(event.pubKey) &&
                (filter['kinds'] as List).contains(event.kind)) {
              socket.add(
                jsonEncode([
                  'EVENT',
                  subId,
                  Nip01EventModel.fromEntity(event).toJson(),
                ]),
              );
            }
          }
        }
        socket.add(jsonEncode(['EOSE', subId]));
      });
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  const unreachable = 'ws://127.0.0.1:9';

  late TinyRelay relay;
  late Ndk ndk;
  late MemCacheManager cache;
  late Bip340EventSigner signer;
  late String pubkey;
  late MemoryUrlListCheckStore checks;

  setUp(() async {
    relay = TinyRelay();
    await relay.start();
    final KeyPair keys = Bip340.generatePrivateKey();
    pubkey = keys.publicKey;
    signer = Bip340EventSigner(
      privateKey: keys.privateKey,
      publicKey: keys.publicKey,
    );
    cache = MemCacheManager();
    ndk = Ndk(
      NdkConfig(
        eventVerifier: Bip340EventVerifier(),
        cache: cache,
        bootstrapRelays: const [unreachable],
      ),
    );
    checks = MemoryUrlListCheckStore();
  });

  tearDown(() async {
    await ndk.destroy();
    await relay.stop();
  });

  Future<Nip01Event> blossomList(String server, {int createdAt = 0}) =>
      signer.sign(
        Nip01Event(
          pubKey: pubkey,
          kind: Blossom.kBlossomUserServerList,
          tags: [
            ['server', server],
          ],
          content: '',
          createdAt: createdAt,
        ),
      );

  Future<UrlListLookup> lookup({String? on, bool offline = false}) =>
      ndkUrlListFn(
        ndk,
        discoveryRelays: [on ?? relay.url],
        queryTimeout: const Duration(milliseconds: 500),
        checks: checks,
        offline: offline,
      )(pubkey, UrlListKind.blossom, const []);

  Future<void> checked({required bool found, required Duration ago}) =>
      checks.write(
        UrlListCheck(
          pubkey: pubkey,
          kind: Blossom.kBlossomUserServerList,
          checkedAt: DateTime.now().toUtc().subtract(ago),
          found: found,
        ),
      );

  List<String>? urls(UrlListLookup lookup) =>
      lookup is UrlListFound ? lookup.urls : null;

  test('reads a freshly checked list from the cache', () async {
    relay.events.add(await blossomList('https://cdn.example'));

    expect(urls(await lookup()), ['https://cdn.example']);
    expect(urls(await lookup()), ['https://cdn.example']);
    expect(relay.requests, 1);

    final check = await checks.read(pubkey, Blossom.kBlossomUserServerList);
    expect(check!.found, isTrue);
  });

  test('a freshly checked missing list needs no relay', () async {
    expect(await lookup(), isA<UrlListNotFound>());
    expect(await lookup(), isA<UrlListNotFound>());
    expect(relay.requests, 1);
  });

  test('asks the relays again once the check is stale', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await cache.saveEvent(
      await blossomList('https://old.example', createdAt: now - 60),
    );
    relay.events.add(await blossomList('https://new.example', createdAt: now));
    await checked(found: true, ago: const Duration(hours: 2));

    expect(urls(await lookup()), ['https://new.example']);
    expect(relay.requests, 1);
    expect(urls(await lookup()), ['https://new.example']);
    expect(relay.requests, 1);
  });

  test('a stale list holds while no relay answers', () async {
    await cache.saveEvent(await blossomList('https://cdn.example'));
    await checked(found: true, ago: const Duration(hours: 2));

    expect(urls(await lookup(on: unreachable)), ['https://cdn.example']);
  });

  test('a stale missing list stays missing while no relay answers', () async {
    await checked(found: false, ago: const Duration(hours: 2));

    expect(await lookup(on: unreachable), isA<UrlListNotFound>());
  });

  test('a list never checked is unavailable while no relay answers', () async {
    expect(await lookup(on: unreachable), isA<UrlListUnavailable>());
  });

  test('asks again for a list found but gone from the cache', () async {
    relay.events.add(await blossomList('https://cdn.example'));
    await checked(found: true, ago: Duration.zero);

    expect(urls(await lookup()), ['https://cdn.example']);
    expect(relay.requests, 1);
  });

  test('sees a list published since the check said there was none', () async {
    await checked(found: false, ago: Duration.zero);
    await cache.saveEvent(await blossomList('https://cdn.example'));

    expect(urls(await lookup()), ['https://cdn.example']);
    expect(relay.requests, 0);
  });

  test('distrusts a check from the future', () async {
    relay.events.add(await blossomList('https://cdn.example'));
    await checked(found: false, ago: const Duration(hours: -2));

    expect(urls(await lookup()), ['https://cdn.example']);
    expect(relay.requests, 1);
  });

  test('offline never asks the relays, whatever the age', () async {
    relay.events.add(await blossomList('https://cdn.example'));

    expect(await lookup(offline: true), isA<UrlListUnavailable>());
    await checked(found: false, ago: const Duration(days: 30));
    expect(await lookup(offline: true), isA<UrlListNotFound>());
    expect(relay.requests, 0);
  });

  test('a check round-trips through its map', () {
    final check = UrlListCheck(
      pubkey: 'p',
      kind: 10002,
      checkedAt: DateTime.utc(2026, 10, 13, 12),
      found: true,
    );
    final read = UrlListCheck.fromMap(
      jsonDecode(jsonEncode(check.toMap())) as Map,
    );
    expect(read.toMap(), check.toMap());
    expect(read.checkedAt, check.checkedAt);
  });
}
