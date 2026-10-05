# safe-vps-ip-switch

[Русская версия](README.ru.md)

A cautious, interactive Bash utility for switching the primary public IPv4 of an Ubuntu VPS that uses **Netplan**.

Designed after a real failure mode where the old VPS IP could no longer reach an upstream service, while a newly attached provider IP worked correctly.

Repository suggestion: **`dagmagnat/safe-vps-ip-switch`**

## Safety goals

The script is intentionally conservative:

- shows the current public IP, interface and gateway before changing anything;
- asks for the new IP (gateway is suggested for `/24` networks);
- backs up `/etc/netplan` and `/etc/nginx` before changes;
- temporarily adds the new IP and checks outbound connectivity from it;
- writes a separate Netplan override instead of destructively rewriting cloud-init files;
- validates Netplan with `netplan generate`;
- updates existing active nginx `proxy_bind OLD_IP;` entries to the new IP, if present;
- validates nginx with `nginx -t`;
- applies networking with `netplan try --timeout 120`, so an unconfirmed broken config is automatically reverted;
- verifies the selected route source and public IPv4;
- supports post-reboot verification and rollback;
- **never deletes/releases the old IP in the hosting provider panel**.

## Supported systems

- Ubuntu 22.04 / 24.04 and similar systems using Netplan
- root access
- IPv4 migration
- `/24` is the default prefix, but another prefix can be supplied

The provider must already have attached/routed the new public IP to the VPS before running the switch.

## Install

```bash
sudo apt update
sudo apt install -y curl python3

git clone https://github.com/dagmagnat/safe-vps-ip-switch.git
cd safe-vps-ip-switch
sudo ./install.sh
```

The installer creates a short system-wide command:

```bash
zamenaip
```

The program is copied to `/usr/local/lib/safe-vps-ip-switch/` and `/usr/local/bin/zamenaip` is created as a symlink. Netplan is normally already installed on supported Ubuntu VPS images.

## Quick start

Start a safe interactive switch from any directory:

```bash
sudo zamenaip
```

Show the current network state:

```bash
zamenaip status
```

Example interaction:

```text
Current network
  Public IPv4 : 194.87.133.17
  Interface   : eth0
  Gateway     : 194.87.133.1

New public IPv4: 5.42.120.63
Gateway [5.42.120.1]:
```

For a known website, add a domain check:

```bash
sudo zamenaip switch --domain hasdgu.ru
```

Non-default network:

```bash
sudo zamenaip switch \
  --new-ip 203.0.113.25 \
  --prefix 24 \
  --gateway 203.0.113.1 \
  --domain example.com
```

## What happens during the switch

The tool creates a timestamped backup under:

```text
/root/safe-vps-ip-switch-backups/YYYYMMDD-HHMMSS/
```

Then it creates:

```text
/etc/netplan/99-safe-vps-ip-switch.yaml
```

The persistent configuration uses the new IPv4, disables DHCPv4 in the merged Netplan config, installs the new default gateway, and keeps any unrelated settings from earlier Netplan files unless overridden.

The final network change is performed with:

```bash
netplan try --timeout 120
```

**Keep the SSH window open.** Confirm the configuration only if SSH and connectivity still work.

## After reboot

Do not detach the old provider IP yet. Reboot first:

```bash
sudo reboot
```

Reconnect using the **new** IP and run:

```bash
sudo zamenaip verify
```

Only when verification succeeds should you detach the old IP in the hosting provider control panel. Verify again before permanently deleting/releasing the old IP.

## Rollback

Restore the latest backup:

```bash
sudo zamenaip rollback
```

Or restore a specific backup:

```bash
sudo zamenaip rollback /root/safe-vps-ip-switch-backups/20261005-120000
```

Rollback restores the backed-up Netplan and nginx configuration and reapplies networking.

## nginx behavior

The script does **not** rewrite `proxy_pass` targets. If an active nginx site already contains a literal binding such as:

```nginx
proxy_bind 194.87.133.17;
```

it is changed to:

```nginx
proxy_bind NEW_IP;
```

and nginx is validated before reload.

If you do not want nginx touched at all:

```bash
sudo zamenaip switch --skip-nginx
```

## Important provider note

This project changes the VPS operating-system network configuration only. It does not call Timeweb Cloud or any other provider API.

Attach/buy the new IP in the provider panel first. Delete/release the old provider IP only after the new configuration survives a reboot and `verify` passes.

## Logs and state

Log:

```text
/var/log/safe-vps-ip-switch.log
```

State used for post-reboot verification:

```text
/var/lib/safe-vps-ip-switch/current.env
```

## Project scope

This tool intentionally does not try to support every Linux network manager or every hosting provider. Keeping the scope to Ubuntu + Netplan makes rollback behavior and safety checks easier to reason about.

## Updating

After `git pull`, run the installer again:

```bash
sudo ./install.sh
```

It atomically replaces the installed copy while keeping the same `zamenaip` command.

## Uninstall

```bash
sudo ./uninstall.sh
```

The uninstaller removes only the installed program and `zamenaip` command. Backups, state, logs, and the active Netplan file are intentionally preserved.

## License

MIT
