# snag — GitHub Release Asset Manager

> [中文版](./README_CN.md)

Download, install, and update GitHub Release assets from the command line.

## Installation

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/resetself/snag/main/install.sh | sh
```

This downloads the latest binary to `~/.local/snag/bin/` and prints PATH setup instructions.

### From source

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
git clone https://github.com/resetself/snag.git
cd snag
zig build -Doptimize=ReleaseFast
cp zig-out/bin/snag ~/.local/snag/bin/
```

### PATH setup

Add `~/.local/snag/bin` to your shell config:

```bash
# bash / zsh
echo 'export PATH="$HOME/.local/snag/bin:$PATH"' >> ~/.bashrc  # or ~/.zshrc

# fish
echo 'fish_add_path ~/.local/snag/bin' >> ~/.config/fish/config.fish
```

## Usage

```
snag install  <repo>              Install to ~/.local/snag/bin/
snag install  <repo> -x <path>    Extract to path, tracked in state
snag download <repo> [path]       Download asset (default: current dir)
snag download <repo> -x [path]    Download + extract (default: current dir)
snag update   <repo>              Update installed repo
snag list                         List installed repos
snag remove   <repo>              Uninstall repo
```

`<repo>` accepts three formats:

```
owner/repo
https://github.com/owner/repo
https://github.com/owner/repo/releases
```

Short forms: `install`=`i`, `download`=`dl`/`d`, `update`=`up`, `list`=`ls`, `remove`=`rm`

## Modes

| Command | Writes state | Description |
|---|---|---|
| `install` | ✅ | Auto-match current platform. Falls back to interactive if ambiguous. Cleans README/LICENSE junk after extract |
| `install -x <path>` | ✅ | Extract to custom path, keep all files |
| `download` | ❌ | Download asset only. Directory created after successful download |
| `download -x` | ❌ | Download + extract. Shows all platform assets |
| `update` | ✅ | Reads state.json, updates using original install method. Supports short names |
| `list` | — | List all installed packages |
| `remove` | ✅ | Recursively deletes install directory, cleans state |

## Options

| Option | Description |
|---|---|
| `-v <tag>` | Release tag (default: latest) |
| `-m, -s <keyword>` | Asset name filter keyword |
| `-os <value>` | Platform/arch filter hint |
| `-i, --interactive` | Force interactive selection |
| `-h, --help` | Show help |

## Interactive Selection

Automatically enters when multiple candidates match. Type to filter in real-time, `↑↓` to navigate, Enter to select, Esc to quit. Shows up to 10 lines.

## State File

`~/.local/snag/state.json` — keyed by `owner/repo`. Records install path, version, match preferences, and more.

## Dependencies

- `tar` — preinstalled on Linux/macOS
- `xz` — `brew install xz` (macOS) / `xz-utils` (Linux)
- `unzip` — for .zip archives

## Examples

```bash
# Install (auto-matches macOS arm64)
snag install blacktop/ida-mcp-rs

# Force interactive selection
snag install blacktop/ida-mcp-rs -i

# Filter by keyword and platform
snag install -m ida-mcp -os Darwin_arm64 blacktop/ida-mcp-rs

# Extract to custom directory
snag install blacktop/ida-mcp-rs -x ~/tools/

# Download to current directory
snag download frida/frida

# Download to specific directory
snag download frida/frida ~/Downloads/

# Download + extract
snag download frida/frida -x

# Update (short name works)
snag update ida-mcp-rs

# List installed
snag list

# Uninstall
snag remove ida-mcp-rs
```

## License

[MIT](LICENSE) © 2026 resetself
