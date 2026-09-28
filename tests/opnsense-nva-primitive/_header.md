# OPNsense 001: Single NVA

Proves the minimal OPNsense NVA deployment with verifiable guest state.

## Bootstrap Tuple (candidate)

> This tuple has not yet passed an integration run. Label changes to "confirmed" once CI passes.

| Component | Value |
|-----------|-------|
| FreeBSD image | `thefreebsdfoundation/freebsd-14_2` `14_2-release-amd64-gen2-zfs:14.2.20250516` |
| Bootstrap script | `opnsense/update` @ `da1985064501` (2025-05-07) |
| OPNsense release | `25.1` |

## Architecture

```text
                          Internet
                             ▲
                             │ SNAT
                      NAT Gateway
                             ▲
                             │
  snet-nva 10.0.1.0/24 ─────┘
  (no UDR)
    └── OPNsense 10.0.1.4
          ← Custom Script Extension (bootstrap)
          ← IP Forwarding: enabled

  snet-test 10.0.2.0/24
  (UDR: 0.0.0.0/0 → VirtualAppliance → 10.0.1.4)
    └── test NIC (for effective-route assertion)
```

## Acceptance Gates

| Layer | Step | Assertion |
|-------|------|-----------|
| L1 | `terraform fmt`, `terraform validate` | Source valid |
| L2 | `terraform plan` | No replacement; no hardcoded secrets |
| L3 | Deploy | Custom Script Extension `provisioningState == Succeeded` |
| L3 | Deploy | OPNsense NIC `enableIpForwarding == true` |
| L4 smoke | Effective routes | `snet-test` NIC default route: `nextHopType=VirtualAppliance`, `nextHopIpAddress=10.0.1.4` |
| L6 | Second plan | `0 add, 0 change, 0 destroy` |
| L6 | Destroy | All resources removed cleanly |

Full bidirectional L4 packet path (request + return, `denied flow really denied`) begins at `opnsense-010-hub-spoke`.

## Next Steps

- `opnsense-010-hub-spoke`: Hub-spoke topology with spoke peering + full UDR
- `opnsense-020-central-egress`: Prove spoke → NVA → Internet flow
