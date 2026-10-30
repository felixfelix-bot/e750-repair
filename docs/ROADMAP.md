# E750 / BSBF / TollGate — roadmap

Status (2026-10-30): **portal live on 2.4 GHz; stale-mint fix applied; kernel
updates blocked on upstream releases; serial console dead (flash gated).**
Default branch: `felixfelix-bot/e750-repair:main` (all work merged via PRs; no open PRs).
Kernel/CVE detail: [`KERNEL-MATRIX.md`](KERNEL-MATRIX.md).
Tracker: [`E750-REMEDIATION.md`](E750-REMEDIATION.md) and
[`BSBF-TOLLGATE-COEXISTENCE.md`](BSBF-TOLLGATE-COEXISTENCE.md).

## Current live state (2026-10-30)

```text
eth0       192.168.8.1/24   management LAN
br-portal  10.0.0.1/24      phy1-ap0 (TollGate-E750, 2.4 GHz ch11/HT20, 20 dBm)
phy1-sta0  hermes-lan       2.4 GHz STA/BSBF primary (shares phy1 with the AP)
5 GHz      disabled         radio1 off, ath10k unloaded (uncalibrated)
wwan0      Aldi Talk 4G     BSBF backup subflow (standby)
BSBF       enabled; EU server in an nspawn container on the OMR host,
           egress 167.235.218.44
TollGate   v0.6.0 + stale-mint fix (kind 10021); portal uhttpd :2051;
           wallet: 3 sats across 2 mints (2 at cubabitcoin earned by the
           gateway, 1 at minibits preserved but unspendable while it is down)
link-mode  metrics every minute; controller observe-only (standby)
portal QoS authenticated guests redirect to the BSBF server; verified
           egress 167.235.218.44 (BSBF/portal xray two-inbound follow-up)
OLED       SSID + link mode + clients + clock every minute
serial     dead: 0/5, empty output — no flash / U-Boot recovery
kernel     E750 6.12.94, MT6000 6.18.39 (both still vulnerable)
health     RESULT OK
```

Verified on 2026-10-29 in combined mode: pre-auth splash/portal 200 and internet
blocked; `ndsctl auth`; post-auth **HTTP 301**; cold boot re-applies the BSBF
tproxy bypass and starts the portal services. The **24 h combined soak** ran
from `2026-10-29T17:17:45Z` and was restarted on 2026-10-30 after the radio and
TollGate reboots.

## 2026-10-30 changes (supersede the 2026-10-29 entries below where noted)

- **Portal radio moved to 2.4 GHz.** The uncalibrated 5 GHz `skip_otp` AP
  deauthenticated a real phone after ~10 s and requested a hardware restart.
  `phy1-ap0` now shares the calibrated 2.4 GHz radio with the STA. CPU idle
  went 0% → 90%, free RAM 22 → 41 MB. See
  [`E750-PORTAL-RADIO-2026-10-30.md`](E750-PORTAL-RADIO-2026-10-30.md).
- **Stale-mint wallet fix.** A stored inactive keyset for a mint answering EOF
  aborted wallet init (`no-reachable-mints`). Fixed upstream and backported;
  the E750 serves `kind 10021` and keeps the 1 sat proof. See
  [`TOLLGATE-STALE-MINT-FIX.md`](TOLLGATE-STALE-MINT-FIX.md).
- **Portal branding + link-mode controller** applied; the image now bakes the
  2.4 GHz portal, `br-portal`, nodogsplash, tproxy, CVE sysctls and crons
  (211 packages, not flashed).
- **MCU/OLED driver**: the NUC029ZAN renders fixed pages from JSON; “TollGate”
  appears via the SSID, not as free text.
- **Serial regressed to 0/5** after closing the enclosure (was 96/100 after the
  re-solder). Flashing and U-Boot recovery remain blocked.
- **Kernel releases checked**: OpenWrt 25.12.6 is `6.12.112` (still one patch
  short), OMR stable `v0.64.2` is `6.18.39`; Ubuntu fix kernels are not
  published. See [`KERNEL-MATRIX.md`](KERNEL-MATRIX.md).

## Completed milestones

| Area | State |
|---|---|
| BSBF client/server IaC | merged; live; failover tested |
| QCA9887 cal-only experiment | negative; reverted; documented |
| Operator access / Dropbear | merged; x280 + T14 keys |
| 4G diagnostics | merged; RF healthy, plan-bumped to ~5 Mbps |
| Serial fault isolation + tools | merged; adapter `BH00DL3M` was bad; re-solder reached 96/100, later regressed |
| Checksummed serial exec | merged; base64 + SHA-256, retransmit, dry-run. See [`SERIAL-CHECKSUM.md`](SERIAL-CHECKSUM.md) |
| Network cleanup + health | merged; WAN zone, `RESULT OK` |
| Health monitor / image | merged; 5-min cron; image with monitor |
| MCU/OLED investigation | merged; protocol confirmed; driver added 2026-10-30 |
| TollGate artifact evaluation | merged; v0.6.0 ath79-nand bundle |
| Separate portal bridge | merged; `br-portal` + AP, management untouched |
| Combined BSBF + TollGate | merged; tproxy bypass, post-auth 301, cold boot |
| Portal role reproducibility | merged; nodogsplash/uhttpd/services in the role |
| Parallel bonding servers | merged; BSBF nspawn next to OMR on Hetzner |
| Portal over the bond | redirect fix merged; verified egress `167.235.218.44`; two-inbound follow-up |
| Portal branding | merged; “TollGate-E750 · Bonded”, localised strings, `/bond.json` badge |
| Link-mode metrics/controller | merged; observe-only, per-minute CSV |
| 2.4 GHz portal move | merged; 5 GHz retired; phone stays associated |
| Stale-mint fix | merged; gonuts/module/PRTA PRs + E750 A/B |
| Reproducible E750 binary | merged; `scripts/build-tollgate-wrt.sh` + backport patch |
| Image bake | built (211 packages); **not flashed** |
| End-to-end payment | real client authenticated; 2 sats earned at cubabitcoin |
| Link-mode decision | standby + observe-only, based on 763 samples |

## Remaining work

### P0 — kernels / CVE-2026-98432

Full per-host table: [`KERNEL-MATRIX.md`](KERNEL-MATRIX.md).

- [x] Hetzner bonding host on `6.12.113`, GRUB pinned; re-run
      `playbook-bonding-servers-hardening.yml` after OMR updates.
- [x] Sysctls + WAN `input=REJECT` + no public MPTCP listener on E750/MT6000.
- [ ] **E750**: 25.12.6 = `6.12.112`; wait for 25.12.7/snapshot or carry the
      kernel patch. Flash is separately blocked by the serial.
- [ ] **MT6000**: OMR stable `v0.64.2` = `6.18.39`; identify the first release
      with `6.18.56+` (`v0.65-snapshot` is the candidate).
- [ ] **Ubuntu**: wait for `7.0.0-43.43` (x280, cobrador, t14) and
      `6.8.0-149.149` (t440); do not reboot onto 42.42/147.147. Re-checked
      after `apt-get update` on 2026-10-30 — still not published.
- [ ] **dq05**: `apt-cache` works but takes ~44 s; candidate `6.17.0-41.41` is
      the running kernel. Map 25.10 to the CVE fix and free space (disk 98%).
- [x] **t14**: local workstation (`T14Gen5`); `sshd` is loopback-only by design
      and work is done locally — not a fleet access blocker.

### P0 — portal-over-bond tproxy

- [x] **Make authenticated guest traffic actually traverse BSBF.** REDIRECT at
      priority -140 to xray `dokodemo-door` on `10.0.0.1:12345`, with
      `ndsRTR`/`fw4` accepts for the redirect port. Verified on the E750:
      pre-auth 307, auth, HTTP/HTTPS egress `167.235.218.44`. Evidence:
      `evidence/portal/2026-10-30_tproxy-fix.txt`.
- [x] **One xray process, two inbounds** (BSBF `127.0.0.1:12345` + portal
      `10.0.0.1:12346`). The role patches both the BSBF template and the live
      config; `xray.config.confdir` is removed so the file is not loaded twice;
      `ensure_rules` matches the port, not just the comment.
- [ ] Re-verify from a veth client **and** a real phone after the two-inbound
      fix: post-auth egress must be `167.235.218.44`, and pre-auth must stay
      blocked.

### P0 — physical / recovery

- [x] Serial re-solder (2026-10-29): 0/5 → **96/100** commands.
- [x] Checksummed serial exec; caught a natural bit flip and retransmitted.
- [ ] **Serial is dead again (0/5, empty) after closing the enclosure.**
      Re-open, inspect the connector/reflow, then verify
      `scripts/serial-tx-test.py` **and** `playbook-e750-serial-check.yml`
      before any flash. This is the hard gate.
- [ ] 100-command wiggle test; if errors cluster, replace the adapter.
- [ ] ZMODEM (`sz`/`rz`) smoke test for file transfer once the link is back.
- [ ] Fresh private backup before any flash or radio experiment.
- [ ] **5 GHz is retired for the portal** (uncalibrated `skip_otp` deauths real
      clients). Keep `radio1` disabled unless real calibration is available.
      History and role: [`E750-RADIO5G.md`](E750-RADIO5G.md).
- [x] Art-blob calibration (`art@0x5000`, `cal-pci`, `skip_otp=0`): ath10k
      still requires OTP and fails `-22`; reverted. See
      [`QCA9887-SKIP-OTP.md`](QCA9887-SKIP-OTP.md).
- [ ] Decide whether to pursue donor calibration/driver work for 5 GHz at all.

### P1 — portal / product

- [x] **End-to-end payment on a real client**: a client (`52:55:a4:72:11:da`,
      `10.0.0.150`) is `Authenticated`, and the wallet earned **2 sats at
      cubabitcoin** (3 sats across 2 mints total). Evidence:
      `evidence/tollgate/2026-10-30_portal-payment-and-linkmode.txt`.
- [ ] **Renewal/logout check** for that client (the first paid session is
      confirmed; expiry and deauth are not).
- [x] **Link-mode decision: keep `wwan0` in standby and the controller
      observe-only.** 763 samples: 4G RTT 39.8 ms vs STA 65.2 ms (ratio 0.71),
      but CPU idle averages **10.5 %**, and only 98/763 samples met the
      aggregate gate. Aggregation also spends mobile data and was slower on
      2026-10-29.
- [ ] **Stale-keyset startup latency**: the fixed build spends ~50 s per
      unreachable keyset before `kind 10021`. Add a short timeout for offline
      keyset fetches.
- [ ] **Mint follow-up**: restore `mint.minibits.cash` when it returns and
      spend/withdraw the preserved 1 sat.
- [ ] **Image/release**: decide the `tollgate-wrt` source (pinned custom feed vs
      offline bundle at first boot); rebuild with the fixed kernel + TollGate
      and flash after the serial gate.
- [ ] **Secrets**: rotate the exposed `hermes-lan` PSK; move the STA PSK/BSBF
      UUID to OpenBao; remove plaintext UCI.
- [ ] **Soak**: restarted after the reboots; complete a clean 24 h window and
      review for unexplained `FAIL`.
- [x] BSBF server location: EU nspawn container on the Hetzner OMR host
      (egress `167.235.218.44`); aggregation stays opt-in.

### P2 — upstream / polish

- [ ] **Merge the upstream stale-mint PRs**:
      gonuts-tollgate#45, tollgate-module-basic-go#1142,
      physical-router-test-automation#330. Then pin the tagged gonuts release
      (replace the pseudo-version) and rebuild.
- [ ] **MCU/OLED**: custom “TollGate” banner needs MCU firmware; the JSON
      protocol has no free-text field. Current driver is the limit.
- [ ] **Reduce upstream-detector noise/load**: the daemon probes
      `192.168.8.254:2121` and `10.120.4.133:2121` every 30 s (3 retries) and
      logs a failure each time. They are not TollGates here. Disable reseller
      probing when the router only acts as a gateway — worthwhile on a device
      with ~10 % CPU idle.
- [ ] **Final audit**: `pytest`, `ansible-playbook --syntax-check`, no secrets,
      no art dumps, all PRs merged, image checksum recorded.
- [ ] Optional: EU latency test, 4G antenna/position, thermal check after the
      enclosure is reopened.

## Inputs needed from the operator

1. Repair/replace the serial adapter (physical) — blocks flashing.
2. A phone and a small Lightning payment for the end-to-end test.
3. Upstream releases: OpenWrt ≥ 6.12.113, OMR ≥ 6.18.56, Ubuntu 43.43/149.149.
4. Decision on the TollGate custom feed for image integration.
5. Whether to pursue 5 GHz calibration at all (currently deferred).

## Acceptance / definition of done

- Combined soak completes with no unexplained `FAIL`.
- Cold boot: BSBF endpoints + portal splash/SPA + post-auth HTTP.
- A real client completes payment and gets internet; logout works.
- Serial recovery is reliable; the console gate passes before any flash.
- E750/MT6000 run a kernel with the CVE fix.
- Image builds with the chosen package set and is flashed only after the serial
  fix; checksum/evidence recorded.
- STA PSK/BSBF UUID in OpenBao; no secrets in the repo.
- All work merged to `main` via PRs; no open PRs.

## Rollback / guardrails

- Portal role has a watchdog and confirm/rollback playbooks; `eth0` management
  is separate from `br-portal`.
- BSBF keeps the management path; portal clients use normal WAN/NAT via the
  tproxy bypass.
- The open AP is only safe while nodogsplash enforces; never leave it up with
  the service stopped.
- Do not flash or run radio experiments without a reliable serial console.
- Do not delete `wallet.db` to “fix” a mint problem; the ecash must survive.
