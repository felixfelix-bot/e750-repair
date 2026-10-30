# Running BSBF and OMR bonding servers in parallel

Status: **in progress.** Target: one Hetzner host runs both bonding-server stacks,
and the E750 carries TollGate guest traffic over the bonded path.

- BSBF: xray/VLESS + MPTCP (this repo)
- OMR: OpenMPTCProuter server (already production for the MT6000)

Default branch: `felixfelix-bot/e750-repair:main`.
Tracker: [`E750-REMEDIATION.md`](E750-REMEDIATION.md) and
[`ROADMAP.md`](ROADMAP.md).

## Why a container, not a second install

The pinned BSBF installer (`bsbf-resources@75a5468`) is destructive in the host
namespace:

```text
curl -fsSL .../Xray-install/install-release.sh | bash -s -- install
systemctl disable --quiet xray
systemctl stop xray
cp /etc/systemd/system/xray@.service /etc/systemd/system/xray-bsbf-bonding@.service
```

On the Hetzner host, `xray.service` is part of OMR (listens `65248-65252`,
`10086`), and `/etc/systemd/system/xray@.service` does not exist. Running the
installer in the host namespace would stop OMR's xray, may shadow
`/usr/lib/systemd/system/xray.service`, and then fail to create the BSBF unit.

A `systemd-nspawn` container with its own PID/mount/net namespaces makes those
commands harmless.

## Topology

```text
Hetzner 167.235.218.44 (Debian 13.7 arm64, OMR kernel 6.18)
├── host namespace: OMR server (unchanged)
│     omr.service, xray.service, shadowsocks-go, glorytun-*, mlvpn
│     ports 65000-65535, ssh 65222
└── container "bsbf1" (Debian 13 arm64, systemd)
      veth: host 10.77.0.1/30 <-> container 10.77.0.2/30
      BSBF xray-bsbf-bonding@ + MPTCP, client ports 16384-16400
      sshd on 10.77.0.2:22 (not published)
      caps: CPUQuota=50%, MemoryMax=1G
```

NAT/DNAT live in `/etc/nftables/custom.d/bsbf.nft`, which `/etc/nftables.conf`
glob-includes **last**, after the OMR ruleset. OMR never writes or deletes files
in `custom.d/`, so the file survives OMR upgrades.

`/etc/nftables.conf` starts with `flush ruleset`, so the custom file must be
self-contained and safe to re-apply. Live applies use
`nft -f /etc/nftables/custom.d/bsbf.nft` only; **never**
`nft -f /etc/nftables.conf`, which would flush and rebuild OMR's live rules.

## MT6000 production protection

The container work touches no OMR service. The only host-level changes are:

- install `systemd-container` + `debootstrap`;
- create the bridge/veth and container;
- add one file under `/etc/nftables/custom.d/`;
- add two `accept` rules to `inet filter forward` for `bsbfbr0`/`ve-bsbf1`
  (OMR's forward chain ends in a reject, so this is required).

Baseline and post-change assertions:

```text
systemctl is-active omr xray shadowsocks-go glorytun-tcp@tun0 glorytun-udp@tun0 mlvpn
ss -lntup -> 65xxx listeners present
MT6000 egress = 167.235.218.44
```

## E750: TollGate over the bonded gateway

Current behaviour: BSBF tproxy **excludes** `br-portal`
(`iifname "br-portal" return`), so guests use plain NAT. Target: authenticated
portal clients use the BSBF tunnel.

Ordering matters: nodogsplash marks authenticated traffic `0x30000` in
`ip mangle` at priority `mangle` (-150). The BSBF tproxy is also at `mangle`.
If tproxy runs first, pre-auth guests bypass the splash.

Design: a new table at priority **-140** (runs after nodogsplash):

```nft
table ip bsbf_portal {
  chain prerouting {
    type filter hook prerouting priority -140; policy accept;
    iifname "br-portal" meta mark & 0x00030000 == 0x00030000 \
      fib daddr type != local meta l4proto { tcp, udp } th dport != 53 \
      tproxy to :12345 meta mark set 0x00030001
  }
}
```

- only the `0x30000` nodogsplash auth mark is tproxied;
- mark becomes `0x30001`, so the BSBF rule becomes `fwmark 0x1/0x1 lookup 1`;
- DNS (`:53`) and local destinations stay local, so dnsmasq and the portal
  services (`:2050`, `:2051`, `:2121`) keep working;
- the main `iifname "br-portal" return` stays, so pre-auth and non-TCP/UDP
  traffic never enters the tunnel.

### What the live bring-up changed

Three details only showed up on the device:

1. **`tproxy to :12345`, not `tproxy to 127.0.0.1:12345`.** With the address
   form, forwarded portal traffic matched the rule but the connection never
   reached xray (HTTPS timed out, no xray outbound socket). The port-only form
   preserves the original destination and works.
2. **`route_localnet=1`** (`net.ipv4.conf.all` and `.default`) is required for
   the tproxy redirect; it is persisted in
   `/etc/sysctl.d/99-bsbf-tproxy.conf`.
3. **The 4G backup was the preferred default route.** UCI said STA metric 9,
   but the kernel route landed at 14 while the cellular route was 13, so the
   throttled 4G won. The cellular metric is now 20 and `verify_bsbf` asserts
   `sta < cell`.

The rule also carries a `counter`, so the match can be observed without
guessing.

Verification: veth client on `br-portal` — pre-auth splash 200 and internet
blocked; `ndsctl auth`; post-auth `curl https://1.1.1.1/cdn-cgi/trace` returns
`ip=167.235.218.44` (the Hetzner BSBF server). Evidence:
`evidence/portal/2026-10-29_portal-over-bond.txt`.

> **2026-10-30 fix — REDIRECT + ndsRTR accept.** The original tproxy matched
> but the delivered flow was dropped by nodogsplash's `ip filter ndsRTR`
> (`ip protocol tcp ... drop`), and xray listened on `127.0.0.1`. The working
> form is a `table inet bsbf_portal` **nat** rule at priority -140:
> `redirect to :12345`, xray `dokodemo-door` on `10.0.0.1:12345` with
> `followRedirect`, plus
> `nft insert rule ip filter ndsRTR tcp dport 12345 accept` and an
> `inet fw4 input` accept for the portal. Verified on the E750: pre-auth 307,
> auth, HTTP/HTTPS egress `167.235.218.44`. The BSBF client and the portal
> now share **one xray process with two inbounds**: BSBF
> `127.0.0.1:12345` (tproxy) and portal `10.0.0.1:12346` (dokodemo-door). The
> role patches both `/usr/share/bsbf/xray.json` and `/etc/xray/config.json`,
> so a later `bsbf-bonding --enable` reproduces the same two-inbound config.
> Evidence: `evidence/portal/2026-10-30_tproxy-fix.txt`.

## Reproducibility contract

No provider snapshot. Everything must be rebuildable from a bare Debian 13:

- rootfs: `mmdebstrap trixie --variant=minbase`, pinned suite/mirror;
- container unit and `.nspawn` file delivered by Ansible;
- network setup in a oneshot unit, idempotent;
- nft rules in `custom.d/bsbf.nft`, self-contained;
- BSBF server role unchanged (pinned commit + Xray version);
- client credentials regenerated by `bsbf-add-client`, stored on the controller
  in `state/bsbf/<host>.json` (0600, gitignored);
- rollback drops the container and the nft file, leaving OMR untouched.

## Checklist

### Phase 1 — plan and scaffolding

- [x] Document the design (this file).
- [x] `roles/bsbf_container`: packages, rootfs, `.nspawn`, network unit, nft file.
- [x] Inventory host `hermes-hel1` (container via `ProxyJump` to `:65222`).
- [x] `playbook-bonding-servers.yml`, `-verify.yml`, `-rollback.yml`.
- [x] Contract tests; `pytest` green (109).

### Phase 2 — deploy and prove coexistence

- [x] Baseline OMR state + MT6000 egress recorded.
- [x] Container created; OMR services/ports unchanged.
- [x] `roles/bsbf_server` applied to the container; client port listening.
- [x] E750 pointed at the new server; endpoints + egress verified.
- [x] Latency before/after measured (connect 15-385 ms -> 7-17 ms).
- [x] Second apply is idempotent; rollback + re-apply rebuilds the container.
      Evidence: `evidence/bonding-servers/2026-10-29_container-cutover.txt`.

### Phase 3 — TollGate over the bond

- [x] `bsbf_portal_tproxy` table + masked fwmark rule in the BSBF role.
- [x] veth client: pre-auth blocked, splash 200, post-auth egress = Hetzner IP.
- [ ] Real phone + ecash payment; post-auth egress = Hetzner IP (payment
      already works; re-check the egress from the phone).
- [x] Memory/RSS measured: ~18 MB available, xray ~14% idle and up to ~71% under
      load. Browsing works; the E750 is close to its CPU ceiling.

### Aggregation vs standby (measured 2026-10-29)

The Aldi Talk plan was upgraded, so the 4G can be measured as a real path:

```text
4G only (STA down)      641 KB/s (~5.1 Mbps), 41-89 ms
MPTCP failover          session survived the STA loss
```

With the 4G as an active (non-backup) subflow, MPTCP does use both paths:

```text
single 50 MB   standby 27.9 Mbps (STA only)
               aggregate 25.5 Mbps, split 61/39
4 x 10 MB      standby 9 s  (~35.5 Mbps, STA only)
               aggregate 39 s (~8.2 Mbps, split 60/40)
```

Aggregation **works mechanically** but is slower: -9% single-stream and ~4x
slower under parallel load. The kernel only exposes the `default` scheduler
(no `mptcp_sched_roundrobin`), and the 4G RTT (41-89 ms) is far worse than the
STA (~29 ms), so the connection head-of-line blocks on the slower subflow.

Decision: keep `wwan0` as a **backup** subflow. Aggregation remains available
by setting `bsbf_backup_interfaces: []`; it is not the default because it
reduces throughput and spends mobile data.

Evidence: `evidence/bonding-servers/2026-10-29_aggregation-test.txt`.

### Phase 4 — merge and record

- [ ] Evidence files under `evidence/bonding-servers/` and `evidence/portal/`.
- [ ] Update `ROADMAP.md`, `E750-REMEDIATION.md`, `E750-PORTAL.md`.
- [ ] PRs merged to `main`; no open PRs.

## Risks

- **E750 memory**: ~12.8 MB available with BSBF + portal running. Guest tproxy
  may OOM the router. Gate: measure RSS, test with one client, fall back to
  plain NAT for guests if unstable.
- **nft ordering**: two `mangle`-priority tables are unordered; the portal table
  must be at `-140` so nodogsplash marks first.
- **Forward chain**: OMR rejects unlisted forwarding; the container rules must be
  added to `inet filter forward` idempotently.
- **Client port API**: `bsbf-add-client-api` binds `0.0.0.0:16383`; it must not
  be published. Manage clients from inside the container.
- **Uncalibrated 5 GHz**: the portal AP runs `skip_otp` without per-device
  calibration; keep txpower low.

## Rollback

```bash
ansible-playbook -i inventory/bsbf-servers.yml playbook-bonding-servers-rollback.yml
```

Stops and removes the container, deletes `custom.d/bsbf.nft` and the forward
rules, leaves OMR/MT6000 untouched. The E750 client is pointed back at
`hermes-nvme` by re-running `playbook-bsbf-client.yml` with the old vars.

## Evidence

- `evidence/bonding-servers/` — baseline, apply, verify, idempotency, rebuild.
- `evidence/portal/` — pre/post-auth, egress through the bond, memory.
