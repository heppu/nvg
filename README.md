# nvg

[![CI](https://github.com/heppu/nvg/actions/workflows/ci.yml/badge.svg)](https://github.com/heppu/nvg/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/heppu/nvg/branch/main/graph/badge.svg)](https://codecov.io/gh/heppu/nvg)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<https://github.com/user-attachments/assets/599e8b9d-436b-45de-853d-9daa3b4b5833>

Seamless navigation between your window manager and applications without plugins.

`nvg` can be used as a drop-in replacement for your window manager's focus command. This allows using your WM's keybindings to control movement also within supported applications.

### Supported Window Managers

| Window Manager | Status |
|----------------|--------|
| Sway           | Full support |
| i3             | Full support (same IPC protocol as Sway) |
| Hyprland       | Full support |
| Niri           | Full support |
| dwm            | Full support ([dwmfifo patch](https://dwm.suckless.org/patches/dwmfifo/) required) |
| awesome        | Planned |

The window manager is auto-detected from environment variables (`SWAYSOCK`, `I3SOCK`, `HYPRLAND_INSTANCE_SIGNATURE`, `NIRI_SOCKET`, `DWM_FIFO`), or can be specified explicitly with `--wm`.

## Installation

### Download binary

Prebuilt Linux binaries for amd64, arm64, and armv7 are available from
[GitHub Releases](https://github.com/heppu/nvg/releases):

```sh
curl -Lo nvg https://github.com/heppu/nvg/releases/latest/download/nvg-linux-amd64
chmod +x nvg
sudo mv nvg /usr/local/bin/
```

### Build from source

Requires [Zig](https://ziglang.org/download/). No other dependencies.

```sh
git clone https://github.com/heppu/nvg.git
cd nvg
sudo zig build install -Doptimize=ReleaseSafe --prefix /usr/local
```

## Setup

### Sway / i3

In your `~/.config/sway/config` (or `~/.config/i3/config`) change all `focus` bindings to use `exec nvg`:

```
bindsym $mod+h exec nvg left
bindsym $mod+j exec nvg down
bindsym $mod+k exec nvg up
bindsym $mod+l exec nvg right
```

That's it. nvg automatically detects the running window manager and
navigates through Neovim, tmux, and VS Code splits/panes before moving to the
next window.

To explicitly select a window manager backend:

```
bindsym $mod+h exec nvg --wm sway left
```

To limit detection to specific applications use explicit hooks list:

```
bindsym $mod+h exec nvg --hooks nvim,tmux left
```

### Hyprland

In your `~/.config/hypr/hyprland.conf`, replace the default `movefocus` bindings:

```
bind = $mod, h, exec, nvg left
bind = $mod, j, exec, nvg down
bind = $mod, k, exec, nvg up
bind = $mod, l, exec, nvg right
```

### Niri

In your `~/.config/niri/config.kdl`, add bindings that call nvg:

```kdl
binds {
    Mod+H { spawn "nvg" "left"; }
    Mod+J { spawn "nvg" "down"; }
    Mod+K { spawn "nvg" "up"; }
    Mod+L { spawn "nvg" "right"; }
}
```

### dwm

Requires the [dwmfifo patch](https://dwm.suckless.org/patches/dwmfifo/) and `xdotool` installed.

Set the `DWM_FIFO` environment variable to enable auto-detection, or use `--wm dwm`:

```sh
export DWM_FIFO=/tmp/dwm.fifo
```

In your `config.h`, add keybindings that call nvg:

```c
static const char *nvg_left[]  = { "nvg", "left",  NULL };
static const char *nvg_down[]  = { "nvg", "down",  NULL };
static const char *nvg_up[]    = { "nvg", "up",    NULL };
static const char *nvg_right[] = { "nvg", "right", NULL };

static const Key keys[] = {
    { MODKEY, XK_h, spawn, {.v = nvg_left} },
    { MODKEY, XK_j, spawn, {.v = nvg_down} },
    { MODKEY, XK_k, spawn, {.v = nvg_up} },
    { MODKEY, XK_l, spawn, {.v = nvg_right} },
};
```

## Supported Applications

| Application | Status |
|-------------|--------|
| Neovim      | Full support |
| tmux        | Full support |
| VS Code     | Detection only (navigation not yet implemented) |

## How It Works

1. Connect to the window manager (auto-detect or `--wm` flag).
2. Get the focused window PID from the WM.
3. Walk the process tree and detect supported applications.
4. Try the **innermost** application first (e.g. nvim before tmux):
   - If it can move in the requested direction, move internally. Done.
   - If at edge, bubble up to the next layer.
5. If all layers are at their edge, move WM window focus.
6. When entering a new window, jump to the split closest to where you came from.

```
 sway window A                      sway window B
+----------------------------+     +----------------------------+
| tmux                       |     | tmux                       |
| +---------++--------------+|     |+--------------++---------+ |
| |  nvim   ||              ||     ||              ||  nvim   | |
| | [split1]||   pane 2     || --> ||   pane 1     || [split1]| |
| | *split2 ||              ||     ||              ||  split2 | |
| +---------++--------------+|     |+--------------++---------+ |
+----------------------------+     +----------------------------+

  focus right from nvim split2:
    1. nvim: at right edge -> bubble up
    2. tmux: at right edge -> bubble up
    3. wm: move focus to window B
    4. enter window B -> land at leftmost tmux pane -> leftmost nvim split
```

## Configuration

| Variable | Description |
|----------|-------------|
| `NVG_DEBUG` | Set to `1` to enable debug logging to stderr |
| `SWAYSOCK` | Path to sway IPC socket (set automatically by sway) |
| `I3SOCK` | Path to i3 IPC socket (set automatically by i3) |
| `HYPRLAND_INSTANCE_SIGNATURE` | Hyprland instance ID (set automatically by Hyprland) |
| `NIRI_SOCKET` | Niri IPC socket path (set automatically by niri) |
| `DWM_FIFO` | Path to dwm FIFO for dwmfifo patch (default: `/tmp/dwm.fifo`) |
| `XDG_RUNTIME_DIR` | Used to locate Hyprland and Neovim sockets |
| `TMUX_TMPDIR` | Tmux socket directory (defaults to `/tmp`) |

### CLI Options

```
Usage: nvg <left|right|up|down> [options]

Options:
  -t, --timeout <ms>      IPC timeout in milliseconds (default: 100)
  --hooks <hook,hook,...>  Comma-separated hooks to enable (default: all)
                            Available: nvim, tmux, vscode
  --wm <name>             Window manager backend (default: auto-detect)
                             Available: sway, i3, hyprland, niri, dwm
  -v, --version            Print version
  -h, --help               Print this help
```

## Development

```sh
zig build test                                     # Run tests
zig build coverage -- --junit zig-out/junit.xml    # Coverage (requires kcov)
zig fmt --check src/ build.zig test_runner.zig     # Check formatting
zig build run -- left                              # Debug build and run
```

## Adding a New Window Manager

Adding support for a new WM requires changes to exactly 5 files (4 source + 1 test):

### 1. `src/<wm>.zig` — IPC client

Create a new file implementing the `WindowManager` vtable (`getFocusedPid`, `moveFocus`, `disconnect`). Use `src/niri.zig` or `src/hyprland.zig` as a template.

### 2. `src/wm.zig` — Backend registration

- Add the new variant to the `Backend` enum
- Add the name to `Backend.fromString()`
- Add the variant to the `Connection` union
- Add auto-detection in `detectBackend()` (check the WM's env var)
- Add the connection case in `connect()`
- Add the name to `backendNames()`
- Update the tests

### 3. `src/main.zig` — CLI help

Add the new WM name to the `--wm` help text in the usage string.

### 4. `README.md` — Documentation

- Add the WM to the "Supported Window Managers" table
- Add a setup section with example keybindings
- Add any env vars to the "Configuration" table

### 5. `test/e2e/test-<wm>.sh` — E2E tests

Create a new test script that implements the adapter interface and calls `run_tests`. The shared test runner in `test/e2e/helpers.sh` exercises the same 6 test groups for every WM. Your script only needs to define the adapter functions:

| Function | Purpose |
|---|---|
| `install_deps` | Install WM packages via apt |
| `start_wm` | Start the WM in headless mode |
| `wm_cleanup` | Clean up WM resources, call `cleanup` at the end |
| `spawn_window` | Spawn a window (terminal) in the WM |
| `wait_for_windows N` | Wait until N windows are visible |
| `get_focused` | Return an identifier for the focused window |
| `wm_focus DIRECTION` | Move focus using the WM's native command |
| `run_nvg DIRECTION` | Invoke `$NVG_BIN` with the correct env/args |

Use `test/e2e/test-sway.sh` as a template. Then register the new test in CI:

- `.github/workflows/ci.yml` — add the WM name to the `matrix.wm` array
- `codecov.yml` — add a new flag under `individual_flags`

## Inspiration

[https://github.com/cjab/nvim-sway](https://github.com/cjab/nvim-sway)
