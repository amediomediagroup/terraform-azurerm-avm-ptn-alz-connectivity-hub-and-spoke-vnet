## Test Assertions

This example must pass:

1. **L1 Source**: `terraform fmt`, `terraform validate`
2. **L2 Plan**: No unexpected replacement
3. **L3 Deploy**: VM running, NIC exists, IP forwarding enabled
4. **L6 Lifecycle**: Second plan = zero diff, destroy succeeds

L4 (packet path) and L5 (failure) are validated starting at `opnsense-010-hub-spoke`.
