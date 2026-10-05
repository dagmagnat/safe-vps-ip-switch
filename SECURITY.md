# Security and operational safety

Changing a VPS primary IP can interrupt remote access. ZAMENAIP reduces the risk but cannot eliminate provider-specific networking behavior.

Before using it:

1. Attach the new IP to the VPS in the provider control panel first.
2. Keep the old provider IP until post-reboot verification succeeds.
3. Keep an out-of-band provider web/VNC/serial console available when possible.
4. Keep the current SSH session open during `netplan try`.
5. Do not release/delete the old provider IP until the new configuration survives a reboot.
6. Provider-side IP discovery and DNS modification are intentionally not guessed without a provider API.

Backups may contain network configuration and nginx configuration. Keep `/var/backups/safe-vps-ip-switch` restricted to root and do not publish backup archives in GitHub issues.

Report security issues privately to the repository owner. Do not include production IP addresses, credentials, API tokens, private keys, or full server configuration in public issues.
