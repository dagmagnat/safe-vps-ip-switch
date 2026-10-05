# Changelog

## 2.0.0 - 2026-10-05

- Reworked the project into a guided operator-friendly TUI-style menu.
- Added first-run Russian/English language selection with persistent settings.
- Added `0 = Back` navigation across submenus.
- Added current-IP inventory and per-address outbound connectivity diagnostics.
- Added selectable detected IPv4 addresses plus manual IPv4/CIDR entry.
- Added temporary-IP and policy-routing preflight tests before persistent changes.
- Added automatic likely-gateway suggestion and real outbound gateway verification.
- Added website and DNS diagnostics with A-record guidance.
- Added interactive backup browser and safe restore flow.
- Added a safety backup before every restore.
- Added explicit reboot confirmation and post-reboot verification workflow.
- Limited automatic nginx edits to exact `proxy_bind` and `listen IP:PORT` directives.
- Added operator help inside the application.
- Improved installer dependency checks and replacement of older `zamenaip` wrappers.
- Updated Russian and English documentation.

## 1.1.0 - 2026-10-05

- Added `install.sh` for a system-wide installation.
- Added the short `zamenaip` command in `/usr/local/bin`.
- Running `zamenaip` without a subcommand starts the safe interactive flow.
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
