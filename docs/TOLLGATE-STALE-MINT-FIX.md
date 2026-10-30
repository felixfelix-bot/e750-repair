# Stale-mint wallet resilience — upstream fix + regression tests

Status: in progress (2026-10-30)

## Problem

The E750 portal showed `no-reachable-mints` although five mints were reachable.
The daemon's `wallet.db` still held an active keyset for `mint.minibits.cash`,
which was down. `loadWalletMints()` is designed to *skip* a keyset whose keys
cannot be fetched and retain the DB record (so the ecash proof survives), but it
only takes that branch when `isNetworkError(err)` is true. The error is
`error getting keyset from mint: Get "https://…/v1/keys/…": EOF` and
`isNetworkError` does not recognise `io.EOF` (and its `*url.Error` is wrapped in
a `fmt.wrapError`, so the type assertion misses too). Result: the whole wallet
init fails, the merchant stays degraded, and the SPA shows a full-page error.

## Fix

1. `OpenTollGate/gonuts-tollgate` — `wallet/offline.go`, `isNetworkError()`:
   - `errors.Is(err, io.EOF)` / `io.ErrUnexpectedEOF` → true;
   - add `"eof"`, `"unexpected eof"`, `"connection closed"` to the substring
     list;
   - use `errors.As` for `*net.OpError`, `*url.Error`, `net.Error`.
2. `OpenTollGate/tollgate-module-basic-go` — bump the gonuts pin and add an
   integration test in `src/tollwallet` that keeps the unreachable keyset’s DB
   record.
3. `OpenTollGate/physical-router-test-automation` — EOF fake mint + a
   regression test proving a stale keyset does not degrade the portal and the
   proof survives.

No `wallet.db` deletion anywhere: the record (and the 1 sat proof) must be kept.

## Checklist

- [x] gonuts: fix `isNetworkError`, unit tests for EOF/wrapped EOF
- [x] gonuts: `LoadWallet` regression test with an EOF mint + a healthy mint
- [x] gonuts: PR OpenTollGate/gonuts-tollgate#45
- [x] module: bump gonuts pin
- [x] module: `TestNewToleratesUnreachableStoredMint`
- [x] module: PR OpenTollGate/tollgate-module-basic-go#1142
- [x] PRTA: `lib/fake_mint.py` EOF + keysets modes
- [x] PRTA: `tests/api/test_mint_stale_keyset_offline.py`
- [x] PRTA: PR OpenTollGate/physical-router-test-automation#330; self-contained test passes on the QEMU lab with the fix and fails on stock v0.6.0
- [x] E750: patched `tollgate-wrt` built and installed
- [x] E750: SPA 200, kind 10021, 1 sat at minibits preserved
- [x] e750-repair: evidence merged; see `evidence/tollgate/2026-10-30_stale-mint-lab-and-e750-ab.txt`

## Evidence to capture

- gonuts `go test ./wallet/...`
- module `go test ./src/tollwallet/...`
- PRTA `pytest --collect-only tests/api/test_mint_stale_keyset_offline.py`
- E750: API event not `no-reachable-mints`, `wallet info` still lists minibits,
  portal 200, post-auth egress.

## Lab + E750 A/B results (2026-10-30)

| target | stock v0.6.0 | v0.6.0 + isNetworkError(EOF) |
|---|---|---|
| QEMU lab (x86_64) | FAIL: kind 21023, `no-reachable-mints` | PASS: kind 10021 |
| GL-E750 (mips) | FAIL: degraded mode, `no-reachable-mints` | OK: kind 10021, portal 200, 1 sat retained |

The PRTA test is now self-contained: two `FakeMintServer`s (healthy + stale with
an inactive keyset without public keys), no external mint or cdk-mintd needed.
The E750 `wallet.db` was never deleted; both minibits keyset records and the
1 sat proof are intact.

Also fixed in the fake mint: `/v1/keys` must only list active keysets **with**
keys (NUT-01), because gonuts' `Keyset.UnmarshalJSON` fails with
`unexpected end of JSON input` on an entry without a `keys` object.
