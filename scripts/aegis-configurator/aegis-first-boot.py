#!/usr/local/bin/python3
"""
AEGIS OPNsense First-Boot Configurator — version 1

Reads deployment policy from Azure customData (/var/lib/waagent/CustomData),
validates it, configures OPNsense firewall rules, then emits a deterministic
AEGIS_OPNSENSE_READY attestation to /dev/console.

TRANSPORT
  Azure delivers customData as a base64-encoded blob. waagent writes it to
  /var/lib/waagent/CustomData. The value in the file is itself base64-encoded
  (Azure wraps once; Terraform base64encode() would wrap twice — we accept
  both single and double encoding and normalise internally).

PAYLOAD SCHEMA
  {
    "schema_version": "1",
    "generation": "<stable deployment hash>",
    "router_ip": "<NVA canonical IP>",
    "allowed_spoke_cidrs": ["<CIDR>", ...]
  }

CONFIGURATOR CONTRACT
  - Fail closed: any parse/validation error = no firewall change + exit 1.
  - Idempotent: re-running with same payload is safe; duplicate rules are
    detected and skipped.
  - No deployment-specific data baked into base image; all policy from payload.
  - Uses OPNsense-supported mechanism: direct config.xml edit +
    /usr/local/etc/rc.filter_configure (same path as UI).
  - Does NOT use PHP functions directly (function namespaces differ by version).
  - Emits AEGIS_OPNSENSE_READY JSON to /dev/console on success.

VERIFIED ON: OPNsense 26.7 (FreeBSD 15.1-RELEASE-p1)
"""

import base64
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CUSTOM_DATA_PATH = "/var/lib/waagent/CustomData"
CONFIG_XML_PATH  = "/conf/config.xml"
FILTER_RELOAD    = "/usr/local/etc/rc.filter_configure"
READY_MARKER     = "/var/db/aegis/ready.json"
SCHEMA_VERSION   = "1"

RULE_DESCR_PREFIX = "AEGIS-spoke-"   # prefix to identify our rules for idempotency


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[aegis-configurator {ts}] {msg}", file=sys.stderr)


def emit_ready(payload: dict):
    """Emit AEGIS_OPNSENSE_READY to /dev/console (collected by Boot Diagnostics)."""
    line = "AEGIS_OPNSENSE_READY " + json.dumps(payload, separators=(",", ":"))
    try:
        with open("/dev/console", "w") as con:
            con.write(line + "\n")
    except Exception as e:
        log(f"WARNING: could not write to /dev/console: {e}")
    print(line)   # also to stdout for local visibility


def fail(reason: str):
    log(f"FAIL: {reason}")
    try:
        with open("/dev/console", "w") as con:
            con.write(f"AEGIS_CONFIGURATOR_FAILED {reason}\n")
    except Exception:
        pass
    sys.exit(1)


# ---------------------------------------------------------------------------
# Step 1: Read and decode customData
# ---------------------------------------------------------------------------

def read_custom_data() -> dict:
    if not os.path.exists(CUSTOM_DATA_PATH):
        fail(f"customData not found at {CUSTOM_DATA_PATH}")

    raw = open(CUSTOM_DATA_PATH, "rb").read().strip()
    log(f"customData raw length: {len(raw)} bytes")

    # Attempt single decode, then double decode
    for attempt in range(2):
        try:
            decoded = base64.b64decode(raw)
            payload = json.loads(decoded)
            log(f"Decoded after {attempt + 1} base64 pass(es)")
            return payload
        except (ValueError, json.JSONDecodeError):
            raw = base64.b64decode(raw)   # try one more level
    fail("customData could not be base64-decoded to valid JSON after 2 attempts")


# ---------------------------------------------------------------------------
# Step 2: Validate payload
# ---------------------------------------------------------------------------

def validate_payload(p: dict) -> dict:
    # schema_version
    sv = p.get("schema_version")
    if str(sv) != SCHEMA_VERSION:
        fail(f"schema_version must be '{SCHEMA_VERSION}', got '{sv}'")

    # generation — non-empty string
    gen = p.get("generation", "").strip()
    if not gen:
        fail("generation must be a non-empty string")

    # router_ip — valid IPv4
    router_ip = p.get("router_ip", "").strip()
    try:
        ipaddress.IPv4Address(router_ip)
    except ValueError:
        fail(f"router_ip '{router_ip}' is not a valid IPv4 address")

    # allowed_spoke_cidrs — list of valid IPv4 networks (may be empty when no spokes yet)
    cidrs_raw = p.get("allowed_spoke_cidrs", [])
    if not isinstance(cidrs_raw, list):
        fail("allowed_spoke_cidrs must be a list")

    validated_cidrs = []
    for cidr in cidrs_raw:
        try:
            net = ipaddress.IPv4Network(str(cidr).strip(), strict=False)
            validated_cidrs.append(str(net))
        except ValueError:
            fail(f"allowed_spoke_cidrs entry '{cidr}' is not a valid IPv4 CIDR")

    log(f"Payload valid: generation={gen}, router_ip={router_ip}, cidrs={validated_cidrs}")
    return {
        "schema_version": SCHEMA_VERSION,
        "generation":     gen,
        "router_ip":      router_ip,
        "allowed_spoke_cidrs": validated_cidrs,
    }


# ---------------------------------------------------------------------------
# Step 3: Assert OPNsense runtime state
# ---------------------------------------------------------------------------

def assert_runtime(router_ip: str):
    # net.inet.ip.forwarding must be 1
    result = subprocess.run(
        ["sysctl", "-n", "net.inet.ip.forwarding"],
        capture_output=True, text=True
    )
    if result.returncode != 0 or result.stdout.strip() != "1":
        fail(f"net.inet.ip.forwarding != 1 (got '{result.stdout.strip()}')")
    log("net.inet.ip.forwarding=1 ✓")

    # PF must be enabled
    result = subprocess.run(["pfctl", "-si"], capture_output=True, text=True)
    if "Enabled" not in result.stdout:
        fail("PF is not enabled")
    log("PF Enabled ✓")

    # OPNsense version reachable
    result = subprocess.run(["opnsense-version", "-v"], capture_output=True, text=True)
    version = result.stdout.strip()
    if not version:
        fail("opnsense-version returned empty")
    log(f"OPNsense version: {version} ✓")

    # router_ip must be configured on an interface
    result = subprocess.run(["ifconfig"], capture_output=True, text=True)
    if router_ip not in result.stdout:
        fail(f"router_ip {router_ip} not found in ifconfig output — wrong deployment?")
    log(f"router_ip {router_ip} present on interface ✓")


# ---------------------------------------------------------------------------
# Step 4: Configure OPNsense firewall rules (idempotent)
# ---------------------------------------------------------------------------

def configure_firewall(generation: str, cidrs: list) -> bool:
    """
    Add one pass rule per spoke CIDR if not already present.
    Returns True if any new rules were written (reload needed).
    """
    if not cidrs:
        log("No spoke CIDRs to configure (empty list — no spokes declared yet)")
        return False
    ET.register_namespace("", "")
    tree = ET.parse(CONFIG_XML_PATH)
    root = tree.getroot()

    # Ensure <filter> section exists
    f = root.find("filter")
    if f is None:
        f = ET.SubElement(root, "filter")

    # Collect existing AEGIS rule descriptions for idempotency check
    existing_descrs = set()
    for rule in f.findall("rule"):
        d = rule.find("descr")
        if d is not None and d.text and d.text.startswith(RULE_DESCR_PREFIX):
            existing_descrs.add(d.text)

    new_rules = 0
    for cidr in cidrs:
        descr = f"{RULE_DESCR_PREFIX}{cidr}"
        if descr in existing_descrs:
            log(f"Rule '{descr}' already present — skipping (idempotent)")
            continue

        rule = ET.SubElement(f, "rule")

        def add(parent, tag, text):
            el = ET.SubElement(parent, tag)
            el.text = text
            return el

        add(rule, "type", "pass")
        add(rule, "ipprotocol", "inet")
        add(rule, "descr", descr)
        add(rule, "direction", "in")
        add(rule, "interface", "lan")
        # protocol omitted = any

        src = ET.SubElement(rule, "source")
        # Proven format: <address>CIDR</address> renders to PF "from <CIDR>"
        add(src, "address", cidr)

        dst = ET.SubElement(rule, "destination")
        add(dst, "any", "1")

        new_rules += 1
        log(f"Added rule: {descr}")

    if new_rules > 0:
        tree.write(CONFIG_XML_PATH, xml_declaration=True, encoding="unicode")
        log(f"config.xml written ({new_rules} new rules)")
        return True

    log("No new rules needed (all already present)")
    return False


# ---------------------------------------------------------------------------
# Step 5: Reload OPNsense filter
# ---------------------------------------------------------------------------

def reload_filter():
    log("Reloading OPNsense filter via rc.filter_configure...")
    result = subprocess.run([FILTER_RELOAD], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"rc.filter_configure exited {result.returncode}: {result.stderr}")
    log("Filter reload complete ✓")


# ---------------------------------------------------------------------------
# Step 6: Verify CIDRs are in active PF ruleset
# ---------------------------------------------------------------------------

def verify_pf_rules(cidrs: list):
    if not cidrs:
        log("No spoke CIDRs to verify (empty list — no spokes declared yet)")
        return
    result = subprocess.run(["pfctl", "-sr"], capture_output=True, text=True)
    pf_rules = result.stdout

    for cidr in cidrs:
        if cidr not in pf_rules:
            fail(f"CIDR {cidr} not found in active PF ruleset after reload")
        log(f"PF rule for {cidr} active ✓")


# ---------------------------------------------------------------------------
# Step 7: Write ready marker + emit attestation
# ---------------------------------------------------------------------------

def write_marker_and_attest(payload: dict):
    os.makedirs(os.path.dirname(READY_MARKER), exist_ok=True)
    with open(READY_MARKER, "w") as f:
        json.dump(payload, f, indent=2)
    log(f"Ready marker written: {READY_MARKER}")

    attestation = {
        "generation":          payload["generation"],
        "router_ip":           payload["router_ip"],
        "forwarding":          True,
        "pf":                  True,
        "allowed_spoke_cidrs": payload["allowed_spoke_cidrs"],
        "configurator_version": "1",
        "timestamp":           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    emit_ready(attestation)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    log("AEGIS first-boot configurator starting")

    # Check for existing ready marker (idempotency across reboots)
    if os.path.exists(READY_MARKER):
        log(f"Ready marker found at {READY_MARKER} — re-emitting attestation")
        existing = json.load(open(READY_MARKER))
        # Re-verify runtime state is still correct
        assert_runtime(existing.get("router_ip", ""))
        verify_pf_rules(existing.get("allowed_spoke_cidrs", []))
        emit_ready({
            "generation":          existing["generation"],
            "router_ip":           existing["router_ip"],
            "forwarding":          True,
            "pf":                  True,
            "allowed_spoke_cidrs": existing["allowed_spoke_cidrs"],
            "configurator_version": "1",
            "timestamp":           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        return

    # Fresh run
    raw_payload = read_custom_data()
    payload     = validate_payload(raw_payload)

    assert_runtime(payload["router_ip"])

    changed = configure_firewall(payload["generation"], payload["allowed_spoke_cidrs"])
    if changed:
        reload_filter()

    verify_pf_rules(payload["allowed_spoke_cidrs"])
    write_marker_and_attest(payload)

    log("AEGIS first-boot configurator complete")


if __name__ == "__main__":
    main()
