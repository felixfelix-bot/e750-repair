#!/usr/bin/env python3
"""Contract checks for TollGate over the BSBF bond."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def test_helper_is_present_and_executable() -> None:
    script = ROOT / "roles/bsbf/files/portal-tproxy.sh"
    assert script.is_file()
    assert script.stat().st_mode & 0o111
    text = script.read_text()
    assert "priority $PRIORITY" in text or "priority -140" in text
    assert "0x00030000" in text
    assert "redirect to :$PORT" in text
    assert 'PORT="${BSBF_PORTAL_TPROXY_PORT:-12346}"' in text
    assert "ndsRTR" in text
    assert "inet fw4 input" in text
    assert "th dport != 53" in text


def test_role_enables_and_persists_it() -> None:
    defaults = read("roles/bsbf/defaults/main.yml")
    assert "bsbf_portal_tproxy: true" in defaults
    assert 'bsbf_portal_interface: "br-portal"' in defaults
    assert 'bsbf_portal_network: "10.0.0.0/24"' in defaults
    assert "bsbf_portal_tproxy_port: 12346" in defaults
    tasks = read("roles/bsbf/tasks/main.yml")
    assert "portal-tproxy.sh" in tasks
    assert "route_localnet" in tasks
    assert "xray-two-inbounds" in tasks
    assert '"127.0.0.1","port":12345' in tasks
    boot = read("roles/bsbf/files/bsbf-bonding-nft")
    assert "portal-tproxy.sh" in boot


def test_both_wan_routes_are_verified() -> None:
    defaults = read("roles/bsbf/defaults/main.yml")
    assert "bsbf_cellular_metric: 13" in defaults
    verify = read("roles/verify_bsbf/tasks/main.yml")
    assert "both WANs have a default route" in verify
    assert "rotates the metrics" in verify


def test_docs_and_evidence_record_the_result() -> None:
    doc = read("docs/BONDING-SERVERS-PARALLEL.md")
    for needle in (
        "priority -140",
        "0x30000",
        "redirect to :12345",
        "12346",
        "ndsRTR",
        "167.235.218.44",
        "evidence/portal/2026-10-30_tproxy-fix.txt",
    ):
        assert needle in doc, needle
    evidence = read("evidence/portal/2026-10-29_portal-over-bond.txt")
    assert "post-auth trace: ip=167.235.218.44" in evidence
    assert "pre-auth trace: blocked" in evidence
    fix = read("evidence/portal/2026-10-30_tproxy-fix.txt")
    assert "ndsRTR" in fix
    assert "167.235.218.44" in fix
