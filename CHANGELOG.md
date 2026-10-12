## 0.2.0

- `ndkUrlListFn` takes a `UrlListCheckStore` to remember when each list was
  last checked. A list checked less than `maxAge` ago resolves from NDK's
  cache without a query, and a list checked before keeps resolving while no
  relay answers. `MemoryUrlListCheckStore` ships with the package.
- `ndkUrlListFn(offline: true)` resolves from NDK's cache and the checks
  alone, without ever querying a relay.

## 0.1.0

- Initial release, extracted from `RelaySet` in `broadcast_queue_shim_for_ndk`
  0.7.0 and renamed to `UrlSet`. Stored maps keep the same format.
- `UrlSet.inbox` and `UrlSet.dm` take one pubkey, like every other leaf. Use
  `UrlSet.union` for several. Stored maps with a `pubkeys` list still load, as
  a union of one leaf per pubkey.
- Add `UrlSet.blossom(pubkey)` for BUD-03 Blossom server lists (kind 10063),
  looked up on the owner's NIP-65 write relays.
- Add `UrlSet.kinds`, so a consumer can reject leaves it cannot use.
- Export `resolveUrlSet` and its `UrlResolution` result.
