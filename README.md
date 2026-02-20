# sway-focus

[![CI](https://github.com/heppu/sway-focus/actions/workflows/ci.yml/badge.svg)](https://github.com/heppu/sway-focus/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/heppu/sway-focus/branch/main/graph/badge.svg)](https://codecov.io/gh/heppu/sway-focus)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<https://github.com/user-attachments/assets/2442c40c-da36-4c5c-9ede-671fbcb4fc11>

Seamless navigation between sway and applications without plugins.

`sway-focus` can be used as a drop-in replacement for `focus` command in sway config. This allows using sway's keybindings to control movement also within supported applications.

## Installation

### Download binary

Prebuilt Linux binaries for amd64, arm64, and armv7 are available from
[GitHub Releases](https://github.com/heppu/sway-focus/releases):

```sh
curl -Lo sway-focus https://github.com/heppu/sway-focus/releases/latest/download/sway-focus-linux-amd64
chmod +x sway-focus
sudo mv sway-focus /usr/local/bin/
```

### Build from source

Requires [Zig](https://ziglang.org/download/). No other dependencies.

```sh
git clone https://github.com/heppu/sway-focus.git
cd sway-focus
sudo zig build install -Doptimize=ReleaseSafe --prefix /usr/local
```

## Setup

In your `~/.config/sway/config` change all `focus` bindings to use `exec sway-focus`:

```
bindsym $mod+h exec sway-focus left
bindsym $mod+j exec sway-focus down
bindsym $mod+k exec sway-focus up
bindsym $mod+l exec sway-focus right
```

That's it. sway-focus automatically detects Neovim, tmux, and VS Code in the
focused window and navigates through their splits/panes before moving to the
next sway window.

To limit detection to specific applications use explicit hooks list:

```
bindsym $mod+h exec sway-focus --hooks nvim,tmux left
```

## Supported Applications

| Application | Status |
|-------------|--------|
| Neovim      | Full support |
| tmux        | Full support |
| VS Code     | Detection only (navigation not yet implemented) |

## How It Works

1. Get the focused window PID from sway.
2. Walk the process tree and detect supported applications.
3. Try the **innermost** application first (e.g. nvim before tmux):
   - If it can move in the requested direction, move internally. Done.
   - If at edge, bubble up to the next layer.
4. If all layers are at their edge, move sway window focus.
5. When entering a new window, jump to the split closest to where you came from.

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
    3. sway: move focus to window B
    4. enter window B -> land at leftmost tmux pane -> leftmost nvim split
```

## Configuration

| Variable | Description |
|----------|-------------|
| `SWAY_FOCUS_DEBUG` | Set to `1` to enable debug logging to stderr |
| `SWAYSOCK` | Path to sway IPC socket (set automatically by sway) |
| `XDG_RUNTIME_DIR` | Used to locate Neovim sockets |
| `TMUX_TMPDIR` | Tmux socket directory (defaults to `/tmp`) |

## Development

```sh
zig build test                                     # Run tests
zig build coverage -- --junit zig-out/junit.xml    # Coverage (requires kcov)
zig fmt --check src/ build.zig test_runner.zig     # Check formatting
zig build run -- left                              # Debug build and run
```

## Inspiration

[https://github.com/cjab/nvim-sway](https://github.com/cjab/nvim-sway)
