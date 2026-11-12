# Creating a VM

Names may contain only letters, digits and `. _ -`, up to 40 characters. `--cpus` defaults to 4 and cannot exceed the host's core count; `--memory` defaults to 8G and cannot exceed half the host's memory; `--disk` is a sparse file that only occupies what is actually written.

## Which kind

| Need | Command | Notes |
| --- | --- | --- |
| Command-line Linux (fastest, recommended) | `macvm create dev --image debian-13` or `--image ubuntu-24.04` | Cloud image, cached after the first download; boots with a login user and the macvm SSH key, ready for `exec` / `ssh` |
| Ubuntu with a desktop | `macvm create desk --desktop ubuntu-desktop` | Offline unattended install; the command returns only once the agent in the installed system responds. The system is in English with the host's time zone |
| Fedora with a desktop | `macvm create desk --desktop fedora-workstation` | After boot the graphical installer must be completed by hand in the window; not suitable for unattended use |
| Windows 11 | `macvm create win --os windows` | Downloads the ARM64 ISO from Microsoft and installs unattended, always deploying with the qemu engine first; the result has a user, OpenSSH and the agent, and after shutting down to eject the install media it boots again automatically. Activation only with `--product-key` |
| macOS | `macvm create mac --os macos` | Without `--ipsw`, downloads the latest version this host supports (about 15–20 GB); once installed it logs in automatically, enables SSH, installs the agent and applies tuning to reduce resource use. Add shared folders with `set` after install |
| Copy a template (any OS) | `macvm create dev2 --template base` | Zero-copy or full-disk copy; gets a new machine identifier and MAC. Templates are saved with `macvm template save <vm> [<template>]` |
| Your own install disc | `macvm create box --os linux --iso FILE` | Boots from the ISO to install; must be operated in the window |

The user name defaults to the host user's name (change with `--user`). Set the password with `--password`; when omitted, cloud images allow key login only, while Ubuntu Desktop, Windows and macOS get a random password stored in `guest-password` inside the VM bundle.

## Engine

`--engine vz` (default, lowest overhead) or `qemu`.

- macOS guests can only use vz.
- Windows always installs with qemu; afterwards you can `macvm set win --engine vz`, but under vz Windows is fixed at 1024x768 with no sound. Keep Windows on qemu if it needs 3D, sound, or a resolution that follows the window.
- Shared folders (virtio-fs) and Rosetta are only available under vz.

## Shared folders

`--share HOST_PATH[:NAME][:ro]`, repeatable; only for macOS and Linux guests on the vz engine. The path inside the guest differs from the host: on Linux it is `/mnt/<NAME>`, on macOS `/Volumes/My Shared Files/<NAME>`.

## After creation

- `macvm set <name> --cpus N --memory 8G --disk-size 256G …` changes configuration and requires shutdown; `--disk-size` can only grow, and the guest partition must be extended separately (Linux created from a cloud image extends it automatically on next boot).
- When unsure what this host supports, run `macvm doctor --json` first.
