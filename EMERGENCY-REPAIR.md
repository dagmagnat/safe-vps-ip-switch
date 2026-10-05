# Emergency repair / Аварийное восстановление

If an old installed version does not know the `update` command, reinstall the
latest main script directly. This requires only `safe-vps-ip-switch.sh` to be
present in the GitHub repository:

```bash
curl -fsSL https://raw.githubusercontent.com/dagmagnat/safe-vps-ip-switch/main/safe-vps-ip-switch.sh -o /tmp/zamenaip-latest.sh
sudo bash -n /tmp/zamenaip-latest.sh
sudo bash /tmp/zamenaip-latest.sh install
zamenaip --version
```

After that, future updates use:

```bash
sudo zamenaip update
```

`zamenaip update` downloads only the main script, validates it with `bash -n`,
backs up the currently installed program, replaces it atomically, repairs the
`/usr/local/bin/zamenaip` symlink, and leaves Netplan/network backups untouched.
