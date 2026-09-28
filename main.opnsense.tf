# Managed OPNsense is an implementation detail of the connectivity PTN.
# The root owns its subnet, NAT association, canonical router address and
# routing integration; this module owns only the appliance resources.
locals {
  opnsense_subnet_ids = {
    for key, value in local.opnsense_hubs : key => try(
      module.hub_and_spoke_vnet.virtual_networks[key].subnet_ids["opnsense_nva"],
      "${module.hub_and_spoke_vnet.resource_id[key]}/subnets/snet-opnsense-nva"
    )
  }

  opnsense_bootstrap_release = {
    for key, value in local.opnsense_hubs : key => coalesce(value.opnsense_nva.bootstrap.release, "25.1")
  }

  opnsense_bootstrap_commit_sha = {
    for key, value in local.opnsense_hubs : key => coalesce(value.opnsense_nva.bootstrap.commit_sha, "da1985064501be4e7e7f35c073f21b5b3a17a6f5")
  }

  opnsense_bootstrap_urls = {
    for key, value in local.opnsense_hubs : key => "https://raw.githubusercontent.com/opnsense/update/${local.opnsense_bootstrap_commit_sha[key]}/src/bootstrap/opnsense-bootstrap.sh.in"
    if value.opnsense_nva.image.source_image_id == null
  }

  # Generation ID: stable hash of deployment parameters.
  # Written to /var/db/aegis/generation on the VM; CI must assert this
  # matches the expected value to reject stale Boot Diagnostics records.
  opnsense_bootstrap_generation = {
    for key, value in local.opnsense_hubs : key => sha256(
      "${key}:${local.opnsense_bootstrap_release[key]}:${local.opnsense_bootstrap_commit_sha[key]}:${local.opnsense_router_ip_addresses[key]}"
    )
    if value.opnsense_nva.image.source_image_id == null
  }
}

module "opnsense_nva" {
  source   = "./modules/opnsense-nva"
  for_each = local.opnsense_hubs

  name      = coalesce(each.value.opnsense_nva.name, "opnsense-${each.key}")
  location  = each.value.location
  parent_id = local.hub_virtual_networks[each.key].parent_id
  subnet_id = local.opnsense_subnet_ids[each.key]

  private_ip_address_allocation = "Static"
  private_ip_address            = local.opnsense_router_ip_addresses[each.key]

  vm_size              = coalesce(each.value.opnsense_nva.compute.vm_size, "Standard_B2ms")
  admin_username       = "azureadmin"
  admin_ssh_public_key = each.value.opnsense_nva.compute.admin_ssh_public_key
  availability_zone    = each.value.opnsense_nva.compute.zone
  source_image_id      = each.value.opnsense_nva.image.source_image_id
  source_image_reference = {
    publisher = "thefreebsdfoundation"
    offer     = "freebsd-14_2"
    sku       = "14_2-release-amd64-gen2-zfs"
    version   = "14.2.20250516"
  }

  enable_ip_forwarding          = true
  enable_accelerated_networking = false
  custom_data                   = null
  enable_telemetry              = var.enable_telemetry
  tags                          = coalesce(each.value.opnsense_nva.tags, var.tags, {})

  retry    = var.retry
  timeouts = var.timeouts

  depends_on = [module.hub_and_spoke_vnet]
}

# Stage 1 only prepares the pinned bootstrap and requests a guest reboot.
# CSE success is deliberately not treated as appliance readiness; 010 remains
# blocked until a deterministic post-boot runtime/configuration proof exists.
resource "azapi_resource" "opnsense_bootstrap_ext" {
  for_each = {
    for key, value in local.opnsense_hubs : key => value
    if value.opnsense_nva.image.source_image_id == null
  }

  type      = "Microsoft.Compute/virtualMachines/extensions@2024-11-01"
  name      = "opnsense-bootstrap"
  location  = each.value.location
  parent_id = module.opnsense_nva[each.key].resource_id
  tags      = coalesce(each.value.opnsense_nva.tags, var.tags, {})

  body = {
    properties = {
      publisher               = "Microsoft.OSTCExtensions"
      type                    = "CustomScriptForLinux"
      typeHandlerVersion      = "1.5"
      autoUpgradeMinorVersion = true
      settings = {
        script = base64encode(<<-SCRIPT
          #!/bin/sh
          set -e
          echo "[opnsense/${each.key}] stage1: preparing bootstrap state machine"

          # ------------------------------------------------------------------
          # Persistent state directory — survives opnsense-bootstrap conversion
          # /var/db/ is preserved; /var/db/pkg/ is wiped but /var/db/aegis/ is not.
          # Do NOT use /tmp (cleared on boot) or /conf (wiped by bootstrap -f).
          # ------------------------------------------------------------------
          AEGIS_STATE_DIR="/var/db/aegis"
          mkdir -p "$AEGIS_STATE_DIR"

          # Generation ID: hash of deployment parameters for stale-record rejection.
          # CI must assert generation matches before accepting a READY attestation.
          GENERATION="${sha256("${each.key}:${local.opnsense_bootstrap_release[each.key]}:${local.opnsense_bootstrap_commit_sha[each.key]}:${local.opnsense_router_ip_addresses[each.key]}")}"
          echo "$GENERATION" > "$AEGIS_STATE_DIR/generation"

          # Persist PREPARED state — visible to all subsequent stages
          echo "PREPARED" > "$AEGIS_STATE_DIR/state"
          echo "[opnsense/${each.key}] state=PREPARED generation=$GENERATION"

          # ------------------------------------------------------------------
          # Fetch pinned bootstrap script (retry for NAT GW association delay)
          # ------------------------------------------------------------------
          for attempt in 1 2 3; do
            fetch -o /usr/local/sbin/opnsense-bootstrap.sh "${local.opnsense_bootstrap_urls[each.key]}" && break
            [ "$attempt" -lt 3 ] || exit 1
            sleep 15
          done
          chmod 700 /usr/local/sbin/opnsense-bootstrap.sh

          # ------------------------------------------------------------------
          # Install aegis-opnsense-ready verifier (runs AFTER final OPNsense boot)
          #
          # Fires when /var/run/booting vanishes (rc.bootup complete) AND all
          # runtime assertions pass. Emits one JSON line to /dev/console →
          # Azure Boot Diagnostics. Idempotent: re-emits on subsequent reboots
          # with same generation until explicitly uninstalled.
          # Terraform values are interpolated here; RCEOF shell vars use \$$ escaping.
          # ------------------------------------------------------------------
          cat > /usr/local/etc/rc.d/aegis_opnsense_ready <<RCEOF
          #!/bin/sh
          # PROVIDE: aegis_opnsense_ready
          # REQUIRE: NETWORKING
          # KEYWORD: nojail

          . /etc/rc.subr

          name="aegis_opnsense_ready"
          rcvar=\$${name}_enable
          start_cmd="\$${name}_start"

          aegis_opnsense_ready_start() {
            local state_dir="/var/db/aegis"
            local generation=\$$(cat "\$${state_dir}/generation" 2>/dev/null || echo "unknown")

            # Wait for /var/run/booting to vanish — prerequisite only.
            # READY is determined by all assertions below, not by this sentinel alone.
            local attempts=0
            while [ -f /var/run/booting ] && [ \$${attempts} -lt 30 ]; do
              sleep 10
              attempts=\$$(( attempts + 1 ))
            done

            # --- Assert: OPNsense release version ---
            local actual_release=\$$(opnsense-version -v 2>/dev/null | awk '{print \$$1}')
            local release_ok="false"
            [ "\$${actual_release}" = "${local.opnsense_bootstrap_release[each.key]}" ] && release_ok="true"

            # --- Assert: IP forwarding enabled (FreeBSD sysctl) ---
            local fwd_val=\$$(sysctl -n net.inet.ip.forwarding 2>/dev/null)
            local forwarding_ok="false"
            [ "\$${fwd_val}" = "1" ] && forwarding_ok="true"

            # --- Assert: PF packet filter is active ---
            local pf_status=\$$(pfctl -si 2>/dev/null | grep -i "^Status:" | awk '{print \$$2}')
            local pf_ok="false"
            [ "\$${pf_status}" = "Enabled" ] && pf_ok="true"

            # --- Assert: canonical router IP assigned to an interface ---
            local ip_ok="false"
            ifconfig | grep -q "${local.opnsense_router_ip_addresses[each.key]}" && ip_ok="true"

            # --- Assert: bootstrap rc.d no longer pending (conversion complete) ---
            local bootstrap_pending="false"
            [ -f /usr/local/etc/rc.d/opnsense_bootstrap ] && bootstrap_pending="true"

            # --- All assertions must pass before emitting READY ---
            # Emit regardless (so CI can see partial failures), but only transition
            # state to READY when all fields are true.
            if [ "\$${release_ok}" = "true" ] && [ "\$${forwarding_ok}" = "true" ] && \
               [ "\$${pf_ok}" = "true" ] && [ "\$${ip_ok}" = "true" ] && \
               [ "\$${bootstrap_pending}" = "false" ]; then
              echo "READY" > "\$${state_dir}/state"
            fi

            # --- Emit structured attestation to console (→ Boot Diagnostics) ---
            # generation field allows CI to reject stale records from prior deployments.
            printf 'AEGIS_OPNSENSE_READY {"generation":"%s","release":"%s","release_ok":%s,"router_ip":"%s","ip_ok":%s,"forwarding":%s,"pf":%s,"bootstrap_pending":%s}\n' \
              "\$${generation}" \
              "\$${actual_release}" "\$${release_ok}" \
              "${local.opnsense_router_ip_addresses[each.key]}" "\$${ip_ok}" \
              "\$${forwarding_ok}" "\$${pf_ok}" \
              "\$${bootstrap_pending}" \
              > /dev/console
          }

          load_rc_config \$${name}
          : \$${aegis_opnsense_ready_enable:=YES}
          run_rc_command "\$$1"
          RCEOF
          chmod 700 /usr/local/etc/rc.d/aegis_opnsense_ready

          # ------------------------------------------------------------------
          # Install bootstrap hook
          #
          # CRITICAL ordering contract:
          #   1. Atomically write BOOTSTRAPPING state BEFORE calling bootstrap.
          #   2. opnsense-bootstrap will reboot the system — code after the call
          #      is NOT guaranteed to execute. No required cleanup may appear
          #      after the bootstrap call.
          #   3. The verifier (aegis_opnsense_ready) runs on the FINAL boot
          #      and reconciles state from BOOTSTRAPPING to READY.
          # ------------------------------------------------------------------
          cat > /usr/local/etc/rc.d/opnsense_bootstrap <<BSEOF
          #!/bin/sh
          # PROVIDE: opnsense_bootstrap
          # REQUIRE: NETWORKING
          # KEYWORD: nojail

          state_dir="/var/db/aegis"

          # Idempotency guard: skip if already past PREPARED state
          current_state=\$$(cat "\$${state_dir}/state" 2>/dev/null || echo "")
          if [ "\$${current_state}" != "PREPARED" ]; then
            echo "[aegis] bootstrap: state=\$${current_state}, skipping (already beyond PREPARED)"
            rm -f /usr/local/etc/rc.d/opnsense_bootstrap
            exit 0
          fi

          # Atomically persist BOOTSTRAPPING BEFORE calling bootstrap.
          # If bootstrap reboots mid-execution this state survives.
          echo "BOOTSTRAPPING" > "\$${state_dir}/state"
          echo "[aegis] bootstrap: state=BOOTSTRAPPING, starting opnsense-bootstrap"

          # Execute bootstrap — this WILL reboot; nothing after this is reliable.
          /usr/local/sbin/opnsense-bootstrap.sh -r ${local.opnsense_bootstrap_release[each.key]} -y
          BSEOF
          chmod 700 /usr/local/etc/rc.d/opnsense_bootstrap

          # ------------------------------------------------------------------
          # Request reboot — CSE exits cleanly after scheduling.
          # Stage 1 is complete.
          # ------------------------------------------------------------------
          echo "[opnsense/${each.key}] stage1 complete: verifier and bootstrap hook installed"
          shutdown -r +1 "OPNsense bootstrap scheduled"
        SCRIPT
        )
      }
    }
  }

  response_export_values    = []
  retry                     = var.retry
  schema_validation_enabled = true
  ignore_body_changes       = []

  timeouts {
    create = "30m"
    delete = "10m"
    read   = "5m"
    update = "30m"
  }

  depends_on = [module.opnsense_nva]
}
