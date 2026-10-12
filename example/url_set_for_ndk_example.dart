import 'package:ndk/ndk.dart';
import 'package:url_set_for_ndk/url_set_for_ndk.dart';

Future<void> main() async {
  final ndk = Ndk(
    NdkConfig(eventVerifier: Bip340EventVerifier(), cache: MemCacheManager()),
  );
  const pubkey =
      '82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2';

  final servers = UrlSet.fallback([
    UrlSet.blossom(pubkey),
    UrlSet.explicit(['https://blossom.primal.net']),
  ]);

  // Store this map in a queue record, resolve it later.
  final stored = servers.toMap();

  final resolution = await resolveUrlSet(
    UrlSet.fromMap(stored),
    ndkUrlListFn(ndk),
  );
  switch (resolution) {
    case UrlsResolved(:final urls):
      print('upload to $urls');
    case UrlsUnavailable(:final reason):
      print('try again later: $reason');
  }

  await ndk.destroy();
}
