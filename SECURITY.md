# Security and operational safety

Changing a VPS primary IP can interrupt remote access. This project reduces that risk but cannot eliminate provider-specific networking behavior.

Before using it:

1. Attach the new IP to the VPS in the provider control panel.
2. Keep an out-of-band provider console available when possible.
3. Keep the current SSH session open during `netplan try`.
4. Do not delete the old provider IP until the new configuration survives a reboot and `verify` passes.
5. Review generated Netplan configuration before confirmation on production systems.

Report security issues privately to the repository owner rather than opening a public issue with sensitive server details.
