# Driving the guest desktop (UI automation)

`macvm ui` reads the guest's accessibility tree, injects mouse and keyboard input, and takes screenshots, all through the guest agent. It works with all three guest OSes and both engines. The VM must be running; `ui` does not start it.

## Loop

1. `macvm ui snapshot <name> --json [--app APP] [--depth N] [--limit N]`: returns `screen`, `apps`, `app`, `nodes` (element ID, role, name, `bounds`) and `truncated`. If the tree is too large, narrow it to the target app with `--app`, or adjust `--depth` / `--limit`; `truncated` being true means not everything was fetched.
2. Prefer acting on elements; it is more reliable than clicking coordinates:
   - `macvm ui act <name> <element> <action> [--value TEXT] --json`; actions are `press`, `focus`, `set-value`, `toggle`, `expand`, `collapse`, `select`, `scroll-into-view`, `show-menu`, `raise`.
   - `macvm ui click <name> --element <element> --json`: clicks the center of the element's current position.
3. When no suitable element exists, use coordinates: `ui click <name> <x> <y> [--button left|right|middle] [--count N]`, `ui move`, `ui drag <name> x1 y1 x2 y2`, `ui scroll <name> <x> <y> [--dx N] [--dy N]` (in wheel notches; positive is right and down).
4. Input: `ui type <name> <text>`, `ui key <name> <combo>` (e.g. `cmd+shift+t`, `enter`).
5. `macvm ui screenshot <name> <file.png> --json`, then look at the image to verify the result; the result includes `width` and `height`.

## Coordinates and IDs

- Coordinates are always pixels of the `ui screenshot` image, with the origin at the top-left of the main screen; `bounds` in `snapshot` use the same coordinates, and `screen.scale` is the factor from guest coordinate units to pixels.
- Element IDs stay valid at least until the next `snapshot`. If an action reports `engine`, take a fresh snapshot before retrying; do not keep reusing old IDs.

## Per-OS pitfalls

- **macOS**: in the guest's System Settings › Privacy & Security, MacVM Agent needs Accessibility (snapshots, actions, input) and Screen Recording (screenshots); without them you get `permission_denied`. The user has to click this in the display window — you cannot do it. The first call after granting reports that the agent is restarting to pick up the permission; the agent restarts on its own, so retry after a few seconds.
- **Linux**: requires a logged-in graphical session. The agent turns on accessibility support at the first snapshot, so some apps that were already running only show up after they are restarted. Under Wayland, elements outside GNOME Shell have no `bounds` and `click --element` reports `engine`; use `act` or click screenshot coordinates instead. Not every program accepts non-ASCII characters from `type`; when one doesn't, use `act --value`. Screenshots fail while the guest screen is off; wake it first with `ui key` or `ui move`.
- **Windows**: works on UAC prompts, the lock screen and the sign-in screen too, and `snapshot` defaults to the foreground program on the secure desktop; but the agent is not running until a user has signed in to the guest at least once.
