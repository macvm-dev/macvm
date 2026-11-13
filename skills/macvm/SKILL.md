---
name: macvm
description: Create and operate macOS / Linux / Windows (ARM64) virtual machines on a Mac with the macvm command line — create, start, stop, suspend, run commands in the guest, SSH, port forwarding, snapshots and templates, and drive the guest desktop (UI automation, screenshots). Use this skill whenever a task involves running something in a VM or an isolated guest, testing on another OS, needing a clean Linux / Windows / macOS environment, or mentions macvm or MacVM — even if the user never says "virtual machine" and only says things like "spin up an Ubuntu to try this", "click something in Windows", or "run it in a sandbox".
---

# macvm

`macvm` is the command line that ships with MacVM. It is built on Apple Virtualization.framework (with an optional QEMU engine) and runs only on Apple silicon Macs.

## Finding the command

Try in order: `macvm` (the App puts a link in `~/.local/bin`), `/usr/local/bin/macvm`, `/Applications/MacVM.app/Contents/Resources/bin/macvm`. If none exists, MacVM is not installed: tell the user to install it, and do not substitute some other virtualization tool on your own.

`macvm <command> --help` is the authority on options; this skill only covers how to use them reliably.

## Always pass `--json`

With `--json`, standard output is exactly one line:

- Success: `{"schemaVersion":1,"result":…}`
- Failure: `{"schemaVersion":1,"error":{"code":"…","message":"…"}}`

Branch on `error.code` or the exit code; do not parse the human-readable output (its format is not stable). Exceptions: `exec`, `ssh` and `proxy` do not support `--json`, because their input and output belong to the guest command; the exit code of `exec` is the guest command's exit code.

| code | Exit code | Meaning and usual handling |
| --- | --- | --- |
| — (no code) | 1 | Other error; read the message |
| `vm_not_found` | 10 | Wrong name; run `macvm ls --json` first |
| `already_exists` | 11 | A VM or template with that name exists; pick another name or confirm the existing one is meant |
| `already_running` | 12 | Already running; changing configuration requires shutting down first |
| `not_running` | 13 | Run `start` first |
| `invalid_config` | 14 | Invalid argument or configuration; also returned when changing configuration while suspended |
| `unsupported` | 15 | Not supported on this host, engine or guest; also used when the agent is missing or too old — follow the message (usually `macvm agent install <name>`) |
| `entitlement_missing` | 16 | An unsigned macvm was used; use the copy bundled with the App. Also: a VM set to bridged networking in the app was run with `macvm run` (use `macvm start`) or with a macvm outside the App bundle |
| `timeout` | 17 | Timed out waiting; retry with a larger `--timeout` |
| `io` | 18 | File or socket read/write failed |
| `engine` | 19 | The virtualization engine reported an error; in UI automation it also means an element ID is stale |
| `snapshot_not_found` | 20 | Snapshot does not exist |
| `template_not_found` | 21 | Template does not exist |
| `permission_denied` | 22 | The guest has not granted the agent a permission (Accessibility or Screen Recording on macOS); the user must grant it inside the guest |

## Basic flow

```bash
macvm ls --json                       # result is an array of VMSummary: name, os, state (stopped|running|suspended), cpuCount, memorySize, ipAddress…
macvm start dev --json                # start in the background, return once ready
macvm wait dev --json                 # wait for the agent (or SSH); starts the VM if it is not running
macvm exec dev -- uname -a            # run in the guest; starts the VM if it is not running
macvm stop dev --json                 # graceful shutdown
```

- Run `ls` first and reuse an existing VM when one fits: creating a new one means downloading an image and installing an OS, which takes minutes to tens of minutes.
- Creating a VM (especially installing macOS, Windows or Ubuntu Desktop) takes a long time; run it in the background and tell the user what you are waiting for.
- The default VM directory holds the user's own VMs. When you create a VM just for testing, ask the user whether to delete it when you are done.

## Confirm before acting

These operations lose data or interrupt something the user is using; confirm with the user before running them: `rm`, `stop --force` (cuts power), `snapshot restore` (overwrites the current disk), `template rm`, `set` on a VM the user already had (changes its configuration), and shutting down a VM you did not start yourself.

## Read details as needed

| Task | Read |
| --- | --- |
| Create a VM: choose the OS, image, engine, network, shared folders, templates | `references/create.md` |
| Run commands in the guest, SSH, ports, shared folder paths, snapshots and clones | `references/guest.md` |
| Drive the guest desktop: accessibility tree snapshots, clicking, typing, screenshots | `references/ui.md` |
