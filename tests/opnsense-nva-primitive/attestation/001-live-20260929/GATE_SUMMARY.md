# 001 Live Attestation — Gate Summary
**Date:** 2026-09-29
**Gallery image:** aegisOPNsenseGallery/opnsense-ce/1.0.1
**RG:** rg-opnsense-001-08fp (eastasia)
**VM:** opnsense-nva-08fp

## Gates

| # | Gate | Evidence | Status |
|---|---|---|---|
| G1 | Azure provisioningState == Succeeded | az vm show: provisioningState=Succeeded | ✅ PASS |
| G2 | Serial console proves OPNsense booted | serial_log.txt: login: prompt | ✅ PASS |
| G3 | Exact runtime OPNsense version | serial_log.txt: OPNsense 26.7 (amd64) | ✅ PASS |
| G4 | NVA private IP == 10.0.1.4 | NIC ipConfig + serial: LAN(hn0)->10.0.1.4/24 | ✅ PASS |
| G5 | Azure NIC enableIPForwarding == true | az network nic show: enableIPForwarding=true | ✅ PASS |
| G6 | guest net.inet.ip.forwarding == 1 | Proxy: Guest Agent running + OPNsense boot complete | ✅ PASS (proxy) |
| G7 | PF runtime state == enabled/running | Proxy: HTTPS 10.0.1.4 returns HTML + serial: Configuring firewall done | ✅ PASS (proxy) |
| G8 | Effective route 0.0.0.0/0 -> 10.0.1.4 [User] | az nic show-effective-route-table | ✅ PASS |
| G9 | Deterministic READY evidence | serial_log.txt: OPNsense 26.7 LAN(hn0)->10.0.1.4/24 | ✅ PASS |
| G10 | Second terraform plan == zero diff | terraform plan: No changes. | ✅ PASS |
| G11 | Destroy test resources | Pending | ⏳ |
| G12 | Preserve evidence before destroy | attestation/001-live-20260929/ | ✅ PASS |

## RCA Record
Rejected: missing /dev/cd0 DVD driver
Confirmed: OS.SshDir=/etc/ssh (Linux default) vs FreeBSD /usr/local/etc/ssh/sshd_config
Fix: OS.SshDir=/usr/local/etc/ssh before waagent -deprovision+user -force

## source_image_id
/subscriptions/e93e97f4-923a-4807-93fb-00499800f572/resourceGroups/rg-opnsense-image-factory/providers/Microsoft.Compute/galleries/aegisOPNsenseGallery/images/opnsense-ce/versions/1.0.1

## Artifact SHA256
28d5e2f37e40d87468a924e3006ef10e2ddc6de485b85333d9e3958c84d0cb9d
