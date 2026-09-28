## Roadmap

### Planned Enhancements

- **040-ha**: Dual NVA with Internal Load Balancer
- **050-private-endpoints**: Private Endpoint routing through NVA
- **060-vpn**: VPN Gateway integration
- **070-private-dns**: Azure DNS Private Resolver integration

### Known Limitations

1. **Single NIC**: Current implementation uses single NIC. Multi-NIC (trust/untrust) separation comes at 040-ha.
2. **No HA**: Single VM deployment. HA with ILB comes at 040-ha.
3. **Bootstrap**: OPNsense requires manual or scripted post-deployment configuration.

## References

- [Hub-spoke network topology in Azure](https://learn.microsoft.com/azure/architecture/reference-architectures/hybrid-networking/hub-spoke)
- [Deploy highly available NVAs](https://learn.microsoft.com/azure/architecture/reference-architectures/dmz/nva-ha)
- [OPNsense Documentation](https://docs.opnsense.org/)
