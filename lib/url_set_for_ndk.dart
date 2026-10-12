/// Relay and Blossom server sets for [ndk](https://pub.dev/packages/ndk),
/// described as a [UrlSet] so they can be persisted offline and resolved
/// later from the lists accounts publish.
library;

export 'src/indexer_relays.dart' show defaultIndexerRelays;
export 'src/ndk_url_lists.dart' show ndkUrlListFn;
export 'src/url_list_checks.dart'
    show MemoryUrlListCheckStore, UrlListCheck, UrlListCheckStore;
export 'src/url_set.dart'
    show
        BlossomUrls,
        DmUrls,
        ExplicitUrls,
        FallbackUrls,
        InboxUrls,
        Nip65Urls,
        OutboxUrls,
        PrivateUrls,
        UnionUrls,
        UrlListFn,
        UrlListFound,
        UrlListKind,
        UrlListLookup,
        UrlListNotFound,
        UrlListUnavailable,
        UrlResolution,
        UrlSet,
        UrlsResolved,
        UrlsUnavailable,
        resolveUrlSet;
