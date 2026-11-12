# Working with the guest

## Running commands

```bash
macvm exec dev -- sh -c 'cd /tmp && make'     # non-interactive; the exit code is the guest command's
macvm exec dev -t -- bash                     # interactive programs need -t for a pseudo-terminal
macvm exec dev --cwd /mnt/src -- cargo test   # --cwd is a path inside the guest
macvm exec dev --user root -- apt-get update  # --user goes through the guest agent (Linux guests)
```

- `exec` starts the VM in the background if it is not running.
- `--cwd` is passed to the guest as is, with no path translation: the host's `$PWD` does not exist in the guest, so use the shared folder's path inside the guest (Linux `/mnt/<name>`, macOS `/Volumes/My Shared Files/<name>`).
- To give host files to the guest, prefer `--share` at creation time; without a shared folder use `macvm cp` (below).

## Copying files

```bash
macvm cp report.pdf src dev:/home/me            # host → guest; the target is an existing directory in the guest
macvm cp 'win:C:\Users\me\Desktop\a.txt' .    # guest → host; write guest paths as absolute paths
```

- Goes through the guest agent and works with all three guest OSes; preserves directory structure and modification times, and between non-Windows systems also permission bits and symbolic links (symbolic links are skipped on Windows).
- When a name collides with an existing item in the target, the copy is renamed with a number (`a.txt` → `a 2.txt`, or `a (2).txt` in a Windows guest) instead of overwriting; `result.files` in the `--json` output lists where each item actually landed.
- Write local paths containing a colon as `./a:b`, otherwise the part before the colon is taken as a VM name.

## SSH and ports

- `macvm ssh <name>`: login shell.
- `macvm ssh-config --install`: generates `~/.config/macvm/ssh_config` (kept up to date by later `create` / `rm`) and adds an Include at the top of `~/.ssh/config`. After that `ssh <vm-name>`, `scp` and `rsync` work directly with the VM name as the host name; connections go through `macvm proxy`, which starts the VM if it is not running — unless it was last stopped by a shutdown, in which case it reports `not_running` and you run `macvm start <name>` first.
- `macvm proxy <name> --port N`: connects standard input and output to a TCP port in the guest (default 22), for use as an ssh ProxyCommand; add `--tcp` to connect straight to the guest IP when the agent is not installed yet.
- `macvm ip <name> --json [--wait SECONDS]`: the guest IP on the host's NAT network (looked up from DHCP leases).
- Port forwarding (TCP only), written `[address:]host-port:guest-port`; the address defaults to `127.0.0.1`, and `0.0.0.0` lets other devices on the network connect:
  - `macvm set <name> --add-forward 8080:80` / `--remove-forward 8080`: saved in the config and active whenever the VM runs; changes take effect immediately, even while running. `create --forward` does the same at creation.
  - `macvm forward <name> 8080:80 [...] --json`: temporary forwards, not saved. The VM must be running (`not_running` otherwise). It prints one line once every port is listening, then keeps running until killed (SIGINT/SIGTERM exits 0) or the VM stops (exit 13). Run it in the background and stop it when done.
  - With the agent installed, connections reach `127.0.0.1:<guest-port>` inside the guest, so loopback-only services work. Without it, the service must listen on the guest's network address. A busy host port fails with `io`.

## Guest agent

`exec --user`, `cp`, the clipboard, UI automation, display size and similar go through macvm-agent inside the guest. When the agent is missing or too old you get `unsupported`; run `macvm agent install <name>` to install or update it (when the agent is online it updates itself without SSH and restarts once). `macvm agent info <name> --json` shows its version and `features`. `macvm update <name> --check` lists whether the agent or guest settings need updating, and `macvm update <name>` updates both through the agent (no SSH needed, the agent restarts once; when `rebootRequired` is true the guest needs a reboot for everything to take effect — add `--reboot`).

## Status and snapshots

- `macvm status <name> --json`: the `VMSummary` of one VM.
- `macvm suspend <name>`: suspends; the next `start` resumes. Not supported for Windows under vz, Linux that is not headless, VMs with install media attached, or the qemu engine with the bundled QEMU — these report `unsupported`.
- `macvm snapshot save|restore|ls|rm`: snapshots; `restore` overwrites the current disk, so confirm with the user first.
- `macvm clone <source> <name>`: clones a stopped VM, zero-copy on APFS.

## Display

- `macvm display <name> 1920x1080`: resizes the display of a running VM (not supported for Windows under vz); without a size it restores the default size.
- The display window opens in the MacVM App. `macvm run <name>` runs headless in the foreground until shutdown (`--console` attaches the guest console); only Homebrew's QEMU can open a separate QEMU window with `run --display`.
