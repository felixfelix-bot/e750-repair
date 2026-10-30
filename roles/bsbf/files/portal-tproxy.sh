#!/bin/sh
# Route authenticated captive-portal clients through the BSBF proxy.
#
# nodogsplash marks authenticated clients 0x30000 in `ip mangle` at priority
# mangle (-150). This table hooks at -140 (nat) and redirects those TCP flows to
# xray's dokodemo-door listener on the portal address. Pre-auth traffic keeps
# its 0x10000/0x20000 mark and is never redirected; ndsNET/ndsRTR still gate it.
#
# Why REDIRECT and not TPROXY (verified on the E750, mips):
#   * TPROXY matched but the delivered flow was dropped by nodogsplash's
#     `ip filter ndsRTR` chain (`ip protocol tcp ... drop`), which only allows
#     the portal ports 22/53/2050/2051/2121. The redirect target is another
#     router-local port, so it needs an explicit accept there.
#   * REDIRECT + xray `followRedirect` works on both x86_64 and mips once the
#     ndsRTR accept and the fw4 input accept are present.
#
# The helper is idempotent. `--ensure` only re-adds the two accept rules; a
# cron runs it every minute so a nodogsplash restart cannot silently drop the
# portal path. UDP from authenticated clients is dropped (except DNS) to force
# QUIC back to TCP; otherwise QUIC would leak past the TCP redirect.
set -e

IFACE="${BSBF_PORTAL_IFACE:-br-portal}"
NETWORK="${BSBF_PORTAL_NETWORK:-10.0.0.0/24}"
PORTAL_IP="${BSBF_PORTAL_IP:-10.0.0.1}"
PRIORITY="${BSBF_PORTAL_PRIORITY:--140}"
PORT="${BSBF_PORTAL_TPROXY_PORT:-12346}"
DROP_UDP="${BSBF_PORTAL_DROP_UDP:-1}"
MARK="bsbf-portal-redirect"

ensure_rules() {
	# TPROXY/REDIRECT makes the flow local. fw4's input chain accepts portal
	# traffic, but nodogsplash's `ip filter ndsRTR` drops all TCP except its
	# allowlist first. Accept the redirect port explicitly, before that drop.
	# Match on the port too: an older release accepted 12345, and the portal
	# now uses 12346, so a comment-only check would leave the new port blocked.
	if nft list chain ip filter ndsRTR >/dev/null 2>&1; then
		if ! nft list chain ip filter ndsRTR | grep -q "tcp dport $PORT .*$MARK"; then
			nft insert rule ip filter ndsRTR tcp dport "$PORT" counter accept comment "$MARK" 2>/dev/null || true
		fi
	fi
	if nft list chain inet fw4 input >/dev/null 2>&1; then
		if ! nft list chain inet fw4 input | grep -q "tcp dport $PORT .*$MARK"; then
			nft insert rule inet fw4 input iifname "$IFACE" tcp dport "$PORT" counter accept comment "$MARK" 2>/dev/null || true
		fi
	fi
}

if [ "${1:-}" = "--ensure" ]; then
	ensure_rules
	exit 0
fi

modprobe nft_redir 2>/dev/null || true

nft list table inet bsbf_portal >/dev/null 2>&1 && nft delete table inet bsbf_portal || true
nft list table inet bsbf_redirect >/dev/null 2>&1 && nft delete table inet bsbf_redirect || true
# Remove the old (broken) IPv4-only tproxy table if it survived an upgrade.
nft list table ip bsbf_portal >/dev/null 2>&1 && nft delete table ip bsbf_portal || true

udp_rule=""
if [ "$DROP_UDP" = "1" ]; then
	udp_rule="iifname \"$IFACE\" ip daddr != $NETWORK meta mark & 0x00030000 == 0x00030000 meta l4proto udp th dport != 53 counter drop"
fi

nft -f - <<NFT
table inet bsbf_portal {
	chain prerouting {
		type nat hook prerouting priority $PRIORITY; policy accept;
		iifname "$IFACE" ip daddr != $NETWORK meta mark & 0x00030000 == 0x00030000 meta l4proto tcp th dport != 53 counter redirect to :$PORT
		$udp_rule
	}
}
NFT

ensure_rules
