#!/bin/sh
# aegis-opnsense-stage1.sh
# Stage 1 bootstrap for Aegis-managed OPNsense NVA.
#
# Called by CustomScriptForLinux v1.x via fileUris + commandToExecute.
# Arguments:
#   $1  opnsense_release    e.g. "25.1"
#   $2  bootstrap_commit    pinned SHA of opnsense/update
#   $3  router_ip           canonical NVA IP e.g. "10.0.1.4"
#   $4  generation          sha256 of deployment params for stale-record rejection
#
# Runs on FreeBSD (stock image before conversion).
# Does NOT use base64/base64 -d — not available in FreeBSD base.
# Uses fetch for HTTP(S) downloads.

set -e

OPNSENSE_RELEASE="$1"
BOOTSTRAP_COMMIT="$2"
ROUTER_IP="$3"
GENERATION="$4"

if [ -z "$OPNSENSE_RELEASE" ] || [ -z "$BOOTSTRAP_COMMIT" ] || [ -z "$ROUTER_IP" ] || [ -z "$GENERATION" ]; then
  echo "[aegis] ERROR: missing required arguments" >&2
  echo "[aegis] Usage: $0 <release> <commit_sha> <router_ip> <generation>" >&2
  exit 1
fi

BOOTSTRAP_URL="https://raw.githubusercontent.com/opnsense/update/${BOOTSTRAP_COMMIT}/src/bootstrap/opnsense-bootstrap.sh.in"
AEGIS_STATE_DIR="/var/db/aegis"

echo "[aegis] stage1 starting: release=${OPNSENSE_RELEASE} router_ip=${ROUTER_IP}"

# Persistent state directory — survives opnsense-bootstrap conversion
# /var/db/ is preserved; /var/db/pkg/ is wiped but /var/db/aegis/ is not.
mkdir -p "$AEGIS_STATE_DIR"
echo "$GENERATION" > "$AEGIS_STATE_DIR/generation"
echo "PREPARED"    > "$AEGIS_STATE_DIR/state"
echo "[aegis] state=PREPARED generation=${GENERATION}"

# Fetch pinned bootstrap script (retry for NAT GW association delay)
for attempt in 1 2 3; do
  fetch -o /usr/local/sbin/opnsense-bootstrap.sh "$BOOTSTRAP_URL" && break
  [ "$attempt" -lt 3 ] || { echo "[aegis] fetch failed after 3 attempts" >&2; exit 1; }
  sleep 15
done
chmod 700 /usr/local/sbin/opnsense-bootstrap.sh

# Install aegis_opnsense_ready verifier
# Fires after final OPNsense boot when all runtime assertions pass.
# Emits AEGIS_OPNSENSE_READY JSON to /dev/console -> Azure Boot Diagnostics.
cat > /usr/local/etc/rc.d/aegis_opnsense_ready << RCEOF
#!/bin/sh
# PROVIDE: aegis_opnsense_ready
# REQUIRE: NETWORKING
# KEYWORD: nojail

. /etc/rc.subr

name="aegis_opnsense_ready"
rcvar=\${name}_enable
start_cmd="\${name}_start"

aegis_opnsense_ready_start() {
  local state_dir="/var/db/aegis"
  local generation=\$(cat "\${state_dir}/generation" 2>/dev/null || echo "unknown")

  # Wait for /var/run/booting to vanish (rc.bootup complete) — prerequisite only
  local attempts=0
  while [ -f /var/run/booting ] && [ \${attempts} -lt 30 ]; do
    sleep 10
    attempts=\$(( attempts + 1 ))
  done

  local actual_release=\$(opnsense-version -v 2>/dev/null | awk '{print \$1}')
  local release_ok="false"
  [ "\${actual_release}" = "${OPNSENSE_RELEASE}" ] && release_ok="true"

  local fwd_val=\$(sysctl -n net.inet.ip.forwarding 2>/dev/null)
  local forwarding_ok="false"
  [ "\${fwd_val}" = "1" ] && forwarding_ok="true"

  local pf_status=\$(pfctl -si 2>/dev/null | grep -i "^Status:" | awk '{print \$2}')
  local pf_ok="false"
  [ "\${pf_status}" = "Enabled" ] && pf_ok="true"

  local ip_ok="false"
  ifconfig | grep -q "${ROUTER_IP}" && ip_ok="true"

  local bootstrap_pending="false"
  [ -f /usr/local/etc/rc.d/opnsense_bootstrap ] && bootstrap_pending="true"

  if [ "\${release_ok}" = "true" ] && [ "\${forwarding_ok}" = "true" ] && \
     [ "\${pf_ok}" = "true" ] && [ "\${ip_ok}" = "true" ] && \
     [ "\${bootstrap_pending}" = "false" ]; then
    echo "READY" > "\${state_dir}/state"
  fi

  printf 'AEGIS_OPNSENSE_READY {"generation":"%s","release":"%s","release_ok":%s,"router_ip":"%s","ip_ok":%s,"forwarding":%s,"pf":%s,"bootstrap_pending":%s}\n' \
    "\${generation}" \
    "\${actual_release}" "\${release_ok}" \
    "${ROUTER_IP}" "\${ip_ok}" \
    "\${forwarding_ok}" "\${pf_ok}" \
    "\${bootstrap_pending}" \
    > /dev/console
}

load_rc_config \${name}
: \${aegis_opnsense_ready_enable:=YES}
run_rc_command "\$1"
RCEOF
chmod 700 /usr/local/etc/rc.d/aegis_opnsense_ready

# Install opnsense_bootstrap hook
# CRITICAL: writes BOOTSTRAPPING BEFORE calling bootstrap.
# opnsense-bootstrap reboots the system — nothing after the call is reliable.
cat > /usr/local/etc/rc.d/opnsense_bootstrap << BSEOF
#!/bin/sh
# PROVIDE: opnsense_bootstrap
# REQUIRE: NETWORKING
# KEYWORD: nojail

state_dir="/var/db/aegis"

current_state=\$(cat "\${state_dir}/state" 2>/dev/null || echo "")
if [ "\${current_state}" != "PREPARED" ]; then
  echo "[aegis] bootstrap: state=\${current_state}, skipping"
  rm -f /usr/local/etc/rc.d/opnsense_bootstrap
  exit 0
fi

echo "BOOTSTRAPPING" > "\${state_dir}/state"
echo "[aegis] bootstrap: state=BOOTSTRAPPING, starting opnsense-bootstrap"

/usr/local/sbin/opnsense-bootstrap.sh -r ${OPNSENSE_RELEASE} -y
BSEOF
chmod 700 /usr/local/etc/rc.d/opnsense_bootstrap

echo "[aegis] stage1 complete: verifier and bootstrap hook installed"
shutdown -r +1 "OPNsense bootstrap scheduled"
