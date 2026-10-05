# ZAMENAIP — Safe VPS IPv4 Switch

[Русская документация](README.ru.md)

Quick operator checklist: [docs/OPERATOR-GUIDE.md](docs/OPERATOR-GUIDE.md)

`ZAMENAIP` is an interactive Bash utility for safely changing the primary IPv4 address on Ubuntu VPS hosts using Netplan. It is designed for operators who may not remember Linux networking commands and need a guided, reversible workflow.

After installation, just run:

```bash
sudo zamenaip
```

On first launch, choose **Русский** or **English**. The choice is saved and can be changed later in Settings.

## Main menu

```text
ZAMENAIP - Safe VPS IPv4 Switch

Current public IPv4: 5.42.120.63    Interface: eth0

  1) IP status and diagnostics
  2) Change primary IPv4
  3) Verify after switch / reboot
  4) Backups and restore
  5) Check website and DNS
  6) Settings / language
  7) Operator guide
  8) Update ZAMENAIP
  0) Exit
```

`0` always means **Back** inside submenus.

## Highlights

- first-run Russian/English language selection;
- persistent language, DNS, and optional website domain settings;
- current public IPv4, interface, gateway, source route, and address inventory;
- outbound connectivity test for each IPv4 already configured in Linux;
- choose a detected IPv4 or enter one manually;
- temporarily add a manually entered IP for preflight testing;
- test the candidate IP and gateway before persistent changes;
- automatically suggest the first host of the IPv4 subnet as a likely gateway;
- timestamped Netplan/nginx/network-state backups;
- `netplan try --timeout 120` rollback protection;
- verify that the selected IPv4 actually became the public/source address;
- update exact active nginx `proxy_bind OLD_IP;` and `listen OLD_IP:PORT` directives;
- run `nginx -t` before reload;
- local and public website checks;
- DNS A-record diagnostics and operator guidance;
- post-reboot verification;
- interactive backup listing and restore;
- safety backup before restore;
- explicit confirmation before reboot;
- built-in GitHub updater via `sudo zamenaip update`;
- automatic repair of stale/hand-made `/usr/local/bin/zamenaip` launchers during installation;
- audit log at `/var/log/safe-vps-ip-switch.log`.

## Provider/API limitation

This project is provider-neutral. It can list IPv4 addresses already visible in Linux, but it cannot generically discover an IP that exists only in a Timeweb/other provider control panel and has not yet been configured in the OS.

Use **Enter a new IPv4 manually** in that case. ZAMENAIP temporarily adds the address and verifies real outbound connectivity before changing persistent networking.

The same applies to DNS: automatic DNS changes require a provider-specific API. ZAMENAIP checks DNS and tells the operator which A record should point to the new address.

## Installation

Standard installation from GitHub:

```bash
git clone https://github.com/dagmagnat/safe-vps-ip-switch.git
cd safe-vps-ip-switch
sudo ./install.sh
```

Or install in one command without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/safe-vps-ip-switch/main/install.sh | sudo bash
```

The remote installer downloads the complete project, validates Bash syntax, and creates the `zamenaip` command.

The installer checks dependencies, installs missing packages through `apt-get` when available, installs the application under `/usr/local/lib/safe-vps-ip-switch/`, and creates the short command `/usr/local/bin/zamenaip`.

To install without launching the menu immediately:

```bash
sudo ./install.sh --no-start
```

Then run from any directory:

```bash
sudo zamenaip
```


## Updating

After installation, you do not need to clone the repository again. Update directly from GitHub with:

```bash
sudo zamenaip update
```

The updater downloads the current `dagmagnat/safe-vps-ip-switch` tree, validates its Bash syntax, shows current/new versions, backs up the installed executable, runs the new installer, and repairs `/usr/local/bin/zamenaip`. It does not change Netplan, current network settings, language configuration, switch state, or network backups.

Force reinstall the same GitHub version:

```bash
sudo zamenaip update --force
```

For migration from an old release that does not yet support `zamenaip update`, run this once:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/safe-vps-ip-switch/main/install.sh | sudo bash -s -- --no-start
```

If only the quick launcher is damaged and you are running the new script directly from a repository checkout:

```bash
sudo ./safe-vps-ip-switch.sh repair
```

## Recommended operator workflow

1. Attach the new IPv4 to the VPS in the hosting-provider control panel, but keep the old IP.
2. SSH into the VPS.
3. Run `sudo zamenaip`.
4. Use option `1` to inspect the current state.
5. Use option `2` to start the guided IP switch.
6. Choose a detected IP or enter it manually.
7. Let ZAMENAIP test the IP and gateway.
8. Confirm the backup and `netplan try` step.
9. Keep the SSH session open until Netplan asks you to confirm the new settings.
10. Check the website and DNS.
11. Reboot when prompted or reboot manually.
12. Run `sudo zamenaip` again and use option `3`.
13. Only after successful post-reboot verification, detach the old provider IP.
14. Verify once more, then permanently release/delete the old provider IP if desired.

## Backups

Create one manually with:

```bash
sudo zamenaip backup
```

Default location:

```text
/var/backups/safe-vps-ip-switch/
```

Each backup contains Netplan, nginx when present, `ip addr`, all routes, `netplan get`, and network metadata.

Restore through the main menu, option `4`. ZAMENAIP creates an additional safety backup before restore.

## CLI shortcuts

```bash
sudo zamenaip              # main menu
sudo zamenaip switch       # guided switch wizard
sudo zamenaip verify       # verify last switch
sudo zamenaip backup       # create a backup
sudo zamenaip rollback     # backup/restore menu
sudo zamenaip language     # change language
sudo zamenaip status       # network status
sudo zamenaip update       # update from GitHub
sudo zamenaip repair       # repair /usr/local/bin/zamenaip
zamenaip --version
```

## Files and state

```text
/etc/safe-vps-ip-switch.conf          language, domain, DNS settings
/etc/netplan/99-zamenaip.yaml         managed Netplan file
/var/lib/safe-vps-ip-switch/          last-switch state
/var/backups/safe-vps-ip-switch/      backups
/var/log/safe-vps-ip-switch.log       log
/usr/local/bin/zamenaip               quick command
```

## Supported environment

Primary target:

- Ubuntu 22.04 / 24.04;
- Netplan;
- standard server networking / systemd-networkd;
- IPv4;
- nginx integration is optional.

The project intentionally does not rewrite CentOS/AlmaLinux, non-Netplan Debian, NetworkManager, or provider-control-plane networking automatically.

## Safety

Remote network changes can always interrupt SSH. On critical systems, keep your provider web/VNC/serial console available.

ZAMENAIP **never releases or deletes an IP from the hosting-provider panel**. Permanent provider-side removal is intentionally left to the operator after successful post-reboot verification.

## License

MIT.
