# Quick operator guide

This checklist is intended for an operator who has never changed a Linux server IP before.

## Before you start

1. Make sure the new IPv4 is already attached to the VPS in the hosting-provider panel.
2. Keep the old IP for now.
3. SSH into the VPS.
4. Run:

```bash
sudo zamenaip
```

## Menu

- `1` — current IP and connectivity diagnostics.
- `2` — change primary IPv4.
- `3` — verify after reboot.
- `4` — backups and restore.
- `5` — website and DNS check.
- `6` — language and settings.
- `0` — back.

## Changing the IP

1. Press `2`.
2. Choose the desired IPv4 from the list.
3. If it is not listed, choose manual entry.
4. Wait for the IP and gateway tests.
5. Review the plan.
6. Confirm the backup.
7. When `netplan try` starts, **keep the SSH session open**.
8. If connectivity remains healthy, confirm Netplan with Enter.
9. Wait for the successful verification message.
10. Reboot when convenient.

## After reboot

Connect again using the new IP, run `sudo zamenaip`, and choose `3`.

If verification passes, detach the old provider IP first. Verify SSH and the website again. Only then permanently release/delete the old IP.

## If something goes wrong

Run `sudo zamenaip`, choose `4`, and restore the latest known-good backup. ZAMENAIP creates an additional safety backup before restore.

## Updating ZAMENAIP

Use the **Update ZAMENAIP** main-menu item or run:

```bash
sudo zamenaip update
```

For a very old installation that does not yet support `update`, run:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/safe-vps-ip-switch/main/install.sh | sudo bash -s -- --no-start
```

This updates the application and repairs the `zamenaip` launcher without changing the current IP or Netplan configuration.
