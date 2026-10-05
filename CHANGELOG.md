# Changelog

## 1.1.0 - 2026-10-05

- Added `install.sh` for a system-wide installation.
- Added the short `zamenaip` command in `/usr/local/bin`.
- Running `zamenaip` without a subcommand now starts the safe interactive switch flow.
- Added `uninstall.sh`; safety backups, logs, state, and Netplan files are preserved on uninstall.
- Updated Russian and English documentation.

## 1.0.0 - 2026-10-05

- Initial release.
- Interactive primary IPv4 switch for Ubuntu/Netplan VPS hosts.
- Timestamped Netplan/nginx backups.
- New-IP outbound connectivity preflight.
- `netplan try` safety window.
- Optional nginx `proxy_bind` migration.
- Post-reboot verification.
- Rollback command.
