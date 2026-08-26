# snag — GitHub Release 资产管理器

> [English](./README.md)

下载、安装、更新 GitHub Release 资产的命令行工具。

## 安装

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/resetself/snag/main/install.sh | sh
```

下载最新二进制到 `~/.local/snag/bin/`，然后按提示配置 PATH。

### 从源码编译

需要 [Zig 0.16.0+](https://ziglang.org/download/)。

```bash
git clone https://github.com/resetself/snag.git
cd snag
zig build -Doptimize=ReleaseFast
cp zig-out/bin/snag ~/.local/snag/bin/
```

### 配置 PATH

```bash
# bash / zsh
echo 'export PATH="$HOME/.local/snag/bin:$PATH"' >> ~/.bashrc  # 或 ~/.zshrc

# fish
echo 'fish_add_path ~/.local/snag/bin' >> ~/.config/fish/config.fish
```

## 用法

```
snag install  <repo>              安装到 ~/.local/snag/bin/
snag install  <repo> -x <path>    解压到 path，写状态
snag download <repo> [path]       下载资产（默认当前目录）
snag download <repo> -x [path]    下载 + 解压（默认当前目录）
snag download -repo <repo> [path] 下载仓库源码
snag install  -repo <repo> [path] 安装仓库源码并写入状态
snag update   <repo>              更新已安装
snag list                         列出已安装
snag remove   <repo>              卸载
```

`<repo>` 支持三种格式：

```
owner/repo
https://github.com/owner/repo
https://github.com/owner/repo/releases
https://github.com/owner/repo/tree/main/path/to/directory
```

只有传入 `-repo` 或 `--repo` 时，仓库 URL 和 `/tree/<ref>/<directory>` URL 才按源码处理。不传该选项时，原有 Release Asset 行为保持不变。

短名：`install`=`i`，`download`=`dl`/`d`，`update`=`up`，`list`=`ls`，`remove`=`rm`

## 模式

| 命令 | 写 state | 说明 |
|---|---|---|
| `install` | ✅ | 自动匹配当前平台，歧义时进入交互选择。解压后清理 README/LICENSE 等垃圾 |
| `install -x <path>` | ✅ | 解压到自定义路径，保留全部文件 |
| `download` | ❌ | 仅下载资产包，下载前不创建目录（成功后才建） |
| `download -x` | ❌ | 下载 + 解压，显示全平台资产 |
| `download -repo` | ❌ | 下载整个源码仓库或 `/tree/...` 指定目录 |
| `install -repo` | ✅ | 安装源码，记录 ref 和 commit，支持更新与卸载 |
| `update` | ✅ | 读取 state.json，按原安装方式更新。支持短名 `snag update jadx` |
| `list` | — | 列出所有已安装 |
| `remove` | ✅ | 递归删除安装目录，清理 state |

> **正文链接回退**：部分项目（如 [caido/caido](https://github.com/caido/caido)）的 Release `assets` 数组为空，下载链接以 `[文本](URL)` 形式写在 release 说明里并指向外部域名。当 assets 为空时，snag 会自动从正文中提取可下载产物链接（按扩展名白名单过滤、去重），当作普通资产走同一套评分/选择流程。

## 选项

| 选项 | 说明 |
|---|---|
| `-v <tag>` | Release 版本；源码模式下表示分支、标签或 commit |
| `-m, -s <keyword>` | 资产名匹配关键字 |
| `-os <value>` | 平台/架构过滤提示 |
| `-i, --interactive` | 强制交互选择 |
| `-repo, --repo` | 下载仓库源码而不是 Release Asset |
| `-h, --help` | 帮助 |

## 交互选择

多候选时自动进入。打字实时过滤，`↑↓` 移动，Enter 选中，Esc 退出。最多显示 10 行。

## 状态文件

`~/.local/snag/state.json`，按 `owner/repo` 键值存储，记录安装路径、版本、匹配偏好等信息。

## 解压依赖

- `tar` — Linux/macOS 通常预装
- `xz` — `brew install xz` (macOS) / `xz-utils` (Linux)
- `unzip` — 处理 .zip 文件

## 示例

```bash
# 安装（自动匹配 macOS arm64）
snag install blacktop/ida-mcp-rs

# 强制交互选择
snag install blacktop/ida-mcp-rs -i

# 关键字过滤 + 指定平台
snag install -m ida-mcp -os Darwin_arm64 blacktop/ida-mcp-rs

# 解压到自定义目录
snag install blacktop/ida-mcp-rs -x ~/tools/

# 下载到当前目录
snag download frida/frida

# 下载到指定目录
snag download frida/frida ~/Downloads/

# 下载 + 解压
snag download frida/frida -x

# 下载整个源码仓库到 /tmp/jebmcp
snag download -repo https://github.com/flankerhqd/jebmcp /tmp/

# 下载指定源码目录到 /tmp/jeb_mcp
snag download -repo https://github.com/flankerhqd/jebmcp/tree/main/jeb-mcp/src/jeb_mcp /tmp/

# -v 可指定源码分支、标签或 commit（也适用于名称包含 '/' 的分支）
snag download -repo -v feature/example https://github.com/owner/repo /tmp/

# 更新（可短名）
snag update ida-mcp-rs

# 查看已安装
snag list

# 卸载
snag remove ida-mcp-rs
```

## 许可证

[MIT](LICENSE) © 2026 resetself
