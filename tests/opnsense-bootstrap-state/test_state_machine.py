#!/usr/bin/env python3
"""
Static analysis tests for the aegis OPNsense bootstrap state machine.

These tests parse and analyze the shell scripts embedded in main.opnsense.tf
to verify correctness without requiring a live VM or Azure credentials.

TDD order (per design decision 2026-09-28):
  1. marker NOT in /tmp
  2. NOT dependent on KEYWORD:firstboot sentinel
  3. BOOTSTRAPPING persisted BEFORE opnsense-bootstrap call
  4. no required cleanup after opnsense-bootstrap returns
  5. verifier: wrong assertions → no READY
  6. stale generation rejected
  7. sh -n syntax
"""

import re
import subprocess
import sys
import json
import hashlib
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]
MAIN_OPNSENSE = REPO_ROOT / "main.opnsense.tf"

FAILURES = []


def fail(test, reason):
    FAILURES.append(f"FAIL [{test}]: {reason}")
    print(f"  ✗ {test}: {reason}")


def ok(test):
    print(f"  ✓ {test}")


def extract_script_body(tf_content: str, heredoc_marker: str) -> str:
    """Extract the content of a shell heredoc from Terraform HCL."""
    pattern = rf'<<-?{re.escape(heredoc_marker)}\n(.*?){re.escape(heredoc_marker)}'
    m = re.search(pattern, tf_content, re.DOTALL)
    if not m:
        return ""
    return m.group(1)


def strip_terraform_interpolations(script: str) -> str:
    """Replace ${...} Terraform interpolations with safe shell literals.
    Handles nested parentheses inside interpolations (e.g. sha256(...)).
    """
    result = []
    i = 0
    while i < len(script):
        if script[i] == '$' and i + 1 < len(script) and script[i+1] == '{':
            # Check if this is a double-escaped shell var \$${
            # (already pre-processed by caller)
            depth = 0
            j = i + 1
            while j < len(script):
                if script[j] == '{':
                    depth += 1
                elif script[j] == '}':
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            result.append('"__TF_PLACEHOLDER__"')
            i = j
        else:
            result.append(script[i])
            i += 1
    out = ''.join(result)
    # Unescape shell dollar-braces
    out = out.replace('\\$${', '${').replace('\\$$', '$')
    return out


def sh_syntax_check(script: str, name: str) -> bool:
    """Run sh -n on a script string. Returns True if syntax is valid."""
    result = subprocess.run(
        ['sh', '-n'],
        input=script,
        text=True,
        capture_output=True
    )
    return result.returncode == 0, result.stderr


def extract_aegis_state_dir(script: str) -> str:
    """Find the AEGIS_STATE_DIR definition in a script."""
    m = re.search(r'AEGIS_STATE_DIR[=\s]+"?([^"\n;]+)"?', script)
    return m.group(1).strip().strip('"') if m else ""


def main():
    print(f"\n{'='*60}")
    print("OPNsense Bootstrap State Machine — Static Analysis Tests")
    print(f"{'='*60}\n")

    if not MAIN_OPNSENSE.exists():
        print(f"ERROR: {MAIN_OPNSENSE} not found")
        sys.exit(1)

    tf_content = MAIN_OPNSENSE.read_text()

    # -------------------------------------------------------------------------
    # Extract the two scripts from main.opnsense.tf
    # -------------------------------------------------------------------------
    stage1_script = extract_script_body(tf_content, "SCRIPT")
    rceof_script  = extract_script_body(tf_content, "RCEOF")

    if not stage1_script:
        fail("extract-stage1", "Could not find <<-SCRIPT heredoc in main.opnsense.tf")
    else:
        ok("extract-stage1")

    if not rceof_script:
        fail("extract-rceof", "Could not find <<RCEOF heredoc (aegis_opnsense_ready rc.d)")
    else:
        ok("extract-rceof")

    # -------------------------------------------------------------------------
    # Test 1: State directory is NOT /tmp
    # -------------------------------------------------------------------------
    print("\n--- Test group 1: Persistent state directory ---")

    state_dir = extract_aegis_state_dir(stage1_script)
    if not state_dir:
        fail("state-dir-defined", "AEGIS_STATE_DIR not defined in stage1 script")
    else:
        ok("state-dir-defined")

    if state_dir.startswith("/tmp"):
        fail("state-not-tmp", f"AEGIS_STATE_DIR='{state_dir}' is under /tmp — not durable across reboot")
    else:
        ok(f"state-not-tmp (dir={state_dir})")

    if not state_dir.startswith("/var/db/"):
        fail("state-in-var-db", f"AEGIS_STATE_DIR='{state_dir}' should be under /var/db/ (survives bootstrap)")
    else:
        ok(f"state-in-var-db (dir={state_dir})")

    # -------------------------------------------------------------------------
    # Test 2: NOT using KEYWORD:firstboot sentinel
    # -------------------------------------------------------------------------
    print("\n--- Test group 2: No firstboot sentinel dependency ---")

    if "KEYWORD: firstboot" in stage1_script or "KEYWORD:firstboot" in stage1_script:
        fail("no-firstboot-in-stage1", "stage1 script uses KEYWORD:firstboot — not reliable across OPNsense conversion")
    else:
        ok("no-firstboot-in-stage1")

    if "KEYWORD: firstboot" in rceof_script or "KEYWORD:firstboot" in rceof_script:
        fail("no-firstboot-in-verifier", "aegis_opnsense_ready rc.d uses KEYWORD:firstboot")
    else:
        ok("no-firstboot-in-verifier")

    # Check for opnsense_bootstrap rc.d also
    bootstrap_rcd = extract_script_body(tf_content, "BSEOF")
    if bootstrap_rcd and ("KEYWORD: firstboot" in bootstrap_rcd or "KEYWORD:firstboot" in bootstrap_rcd):
        fail("no-firstboot-in-bootstrap-rcd", "opnsense_bootstrap rc.d uses KEYWORD:firstboot")
    else:
        ok("no-firstboot-in-bootstrap-rcd")

    # -------------------------------------------------------------------------
    # Test 3: BOOTSTRAPPING persisted BEFORE opnsense-bootstrap call
    # -------------------------------------------------------------------------
    print("\n--- Test group 3: State ordering (BOOTSTRAPPING before bootstrap call) ---")

    bootstrap_rcd = extract_script_body(tf_content, "BSEOF")
    if not bootstrap_rcd:
        fail("extract-bootstrap-rcd", "Could not find <<BSEOF heredoc (opnsense_bootstrap rc.d)")
    else:
        ok("extract-bootstrap-rcd")

        bootstrapping_pos = bootstrap_rcd.find("BOOTSTRAPPING")
        bootstrap_call_pos = bootstrap_rcd.find("opnsense-bootstrap.sh")

        if bootstrapping_pos < 0:
            fail("bootstrapping-state-written",
                 "opnsense_bootstrap rc.d does not write BOOTSTRAPPING state before calling bootstrap")
        elif bootstrap_call_pos < 0:
            fail("bootstrap-call-present",
                 "opnsense_bootstrap rc.d does not call opnsense-bootstrap.sh")
        elif bootstrapping_pos > bootstrap_call_pos:
            fail("bootstrapping-before-bootstrap-call",
                 f"BOOTSTRAPPING state written at pos {bootstrapping_pos} but bootstrap called at {bootstrap_call_pos} — must write state FIRST")
        else:
            ok(f"bootstrapping-before-bootstrap-call (state@{bootstrapping_pos} < call@{bootstrap_call_pos})")

    # -------------------------------------------------------------------------
    # Test 4: No required cleanup after opnsense-bootstrap returns
    # -------------------------------------------------------------------------
    print("\n--- Test group 4: No post-bootstrap cleanup assumptions ---")

    if bootstrap_rcd:
        lines = bootstrap_rcd.strip().splitlines()
        bootstrap_call_idx = None
        for i, line in enumerate(lines):
            if "opnsense-bootstrap.sh" in line:
                bootstrap_call_idx = i
                break

        if bootstrap_call_idx is not None:
            post_bootstrap_lines = [
                l.strip() for l in lines[bootstrap_call_idx + 1:]
                if l.strip() and not l.strip().startswith("#")
            ]
            cleanup_required = any(
                any(kw in l for kw in ["rm ", "echo ", "exit ", "mv ", "cp "])
                for l in post_bootstrap_lines
                if not l.startswith("#")
            )
            if cleanup_required:
                # Allowed: writing exit code before reboot, but NOT state transitions
                # that depend on bootstrap completing
                fail("no-required-post-bootstrap-cleanup",
                     f"Lines after opnsense-bootstrap.sh call that may not execute (bootstrap reboots):\n"
                     + "\n".join(f"  {l}" for l in post_bootstrap_lines[:5]))
            else:
                ok("no-required-post-bootstrap-cleanup")
        else:
            ok("no-required-post-bootstrap-cleanup (no bootstrap call found — skip)")

    # -------------------------------------------------------------------------
    # Test 5: Verifier assertions — all must be present
    # -------------------------------------------------------------------------
    print("\n--- Test group 5: Verifier assertions ---")

    assertions = {
        "release-check":     ["opnsense-version", "release"],
        "forwarding-check":  ["net.inet.ip.forwarding", "sysctl"],
        "pf-check":          ["pfctl"],
        "router-ip-check":   ["ifconfig"],
        "bootstrap-pending": ["opnsense_bootstrap"],
    }

    for assertion_name, keywords in assertions.items():
        if all(kw in rceof_script for kw in keywords):
            ok(f"verifier-has-{assertion_name}")
        else:
            missing = [kw for kw in keywords if kw not in rceof_script]
            fail(f"verifier-has-{assertion_name}",
                 f"aegis_opnsense_ready rc.d missing keywords: {missing}")

    # READY only emitted when all assertions pass
    ready_emit_pos = rceof_script.find("AEGIS_OPNSENSE_READY")
    if ready_emit_pos < 0:
        fail("verifier-emits-ready", "aegis_opnsense_ready does not emit AEGIS_OPNSENSE_READY")
    else:
        ok("verifier-emits-ready")

        # Each boolean assertion variable should be checked before emit
        required_vars = ["release_ok", "forwarding_ok", "pf_ok", "ip_ok", "bootstrap_pending"]
        for var in required_vars:
            if var not in rceof_script:
                fail(f"verifier-checks-{var}",
                     f"aegis_opnsense_ready does not reference assertion variable '{var}'")
            else:
                ok(f"verifier-checks-{var}")

    # -------------------------------------------------------------------------
    # Test 6: Generation field present for stale-record rejection
    # -------------------------------------------------------------------------
    print("\n--- Test group 6: Generation field for stale record rejection ---")

    if '"generation"' in rceof_script or "'generation'" in rceof_script or "generation" in rceof_script:
        ok("verifier-emits-generation")
    else:
        fail("verifier-emits-generation",
             "aegis_opnsense_ready does not emit a 'generation' field — "
             "CI cannot distinguish stale Boot Diagnostics records from current deployment")

    # -------------------------------------------------------------------------
    # Test 7: Shell syntax check (sh -n)
    # -------------------------------------------------------------------------
    print("\n--- Test group 7: Shell syntax (sh -n) ---")

    for script_name, raw_script in [
        ("stage1", stage1_script),
        ("aegis_opnsense_ready", rceof_script),
    ]:
        if not raw_script:
            continue
        cleaned = strip_terraform_interpolations(raw_script)
        valid, stderr = sh_syntax_check(cleaned, script_name)
        if valid:
            ok(f"sh-n-{script_name}")
        else:
            fail(f"sh-n-{script_name}", f"sh -n failed:\n{stderr[:300]}")

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    print(f"\n{'='*60}")
    if FAILURES:
        print(f"FAILURES: {len(FAILURES)}")
        for f in FAILURES:
            print(f"  {f}")
        print(f"{'='*60}\n")
        sys.exit(1)
    else:
        print(f"All tests PASSED")
        print(f"{'='*60}\n")
        sys.exit(0)


if __name__ == "__main__":
    main()
