# -----------------------------------------------------------------------------
# OPNsense NVA Submodule
# -----------------------------------------------------------------------------
#
# Scenario Progression:
#   001-single-nva  → VM + NIC + IP forwarding + bootstrap  (this phase)
#   010-hub-spoke   → Hub/spoke + peering + UDR
#   020-egress      → Spoke → NVA → Internet
#   030-east-west   → Spoke ↔ NVA ↔ Spoke
#   040-ha          → 2 NVAs + ILB + failover
#
# Current Phase: single-nva
#   - Single NIC
#   - IP forwarding enabled
#   - No ILB/HA (added at 040)
#   - No multi-NIC trust/untrust (added at 040)
#
# -----------------------------------------------------------------------------
