const std = @import("std");
const builtin = @import("builtin");
const cURL = @cImport({
    @cInclude("curl/curl.h");
});

// ============================================================================
// 类型定义
// ============================================================================

/// 子命令枚举
const SubCommand = enum { install, download, update, list, remove };

/// 候选资产：从 GitHub Release 中筛选出的可下载文件
const AssetCandidate = struct {
    name: []const u8, // 文件名
    browser_download_url: []const u8, // 下载地址
    release_tag: []const u8, // 发布版本标签
    score: u8, // 匹配置信度评分，越高越匹配当前平台
    matches_platform: bool, // 是否匹配自动检测的 OS/Arch
    matches_keyword: bool, // 是否匹配 -m 关键词
    matches_os_filter: bool, // 是否匹配 -os 筛选
};

/// 安装记录：存储在 state.json 中的每条安装信息
const InstallRecord = struct {
    repo_url: []const u8, // 仓库完整 URL
    repo_slug: []const u8, // 仓库标识 owner/name（不含 @asset）
    install_dir: []const u8, // 安装目标目录
    installed_version: []const u8, // 已安装版本
    selected_asset_name: []const u8, // 选中的资产文件名
    selected_download_url: []const u8, // 实际下载 URL
    install_mode: []const u8, // "archive_extract" 或 "raw_file"
    install_type: []const u8, // "lean"（清理杂项文件）或 "full"（保留全部）
    installed_files: []const []const u8, // 安装产生的文件/目录列表
    selected_match_keyword: ?[]const u8, // 记录 -m 关键词（用于 update 时匹配）
    selected_os_arch: ?[]const u8, // 记录 -os 平台标识（用于 update 时匹配）
    installed_at: []const u8, // ISO 8601 安装时间戳
};

/// 状态文件：内存中的安装记录集合
const StateFile = struct {
    records: std.StringHashMap(InstallRecord),
    allocator: std.mem.Allocator,

    /// 释放所有记录内存
    fn deinit(self: *StateFile) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeRecordFields(self.allocator, @constCast(entry.value_ptr));
        }
        self.records.deinit();
    }
};

/// 命令行参数
const Args = struct {
    cmd: SubCommand = .install,
    url: ?[]const u8 = null, // 仓库 URL 或 owner/repo
    version: ?[]const u8 = null, // 指定版本标签（-v）
    match_keyword: ?[]const u8 = null, // 资产名关键词筛选（-m/-s）
    os_arch: ?[]const u8 = null, // 平台/架构筛选提示（-os）
    output: ?[]const u8 = null, // 自定义输出目录
    extract: bool = false, // -x 解压模式
    interactive: bool = false, // -i 强制交互式选择
    help: bool = false,
};

/// 解析后的仓库标识（owner + name）
const RepoSlug = struct {
    owner: []const u8,
    name: []const u8,
};

/// GitHub Release API 响应结构
const Release = struct {
    tag_name: []const u8,
    assets: []const ReleaseAsset,
};

/// Release 中的单个资产
const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

/// 平台特征提示：用于资产名评分匹配
const PlatformHints = struct {
    label: []const u8, // 可读标签如 "macos/arm64"
    os: []const []const u8, // OS 别名字符串列表
    arch: []const []const u8, // 架构别名字符串列表
    other_os: []const []const u8, // 不兼容的 OS（匹配上则排除）
    other_arch: []const []const u8, // 不兼容的架构（匹配上则排除）
    generic: []const []const u8 = &empty_aliases, // 通用标识如 "universal"
};

const empty_aliases = [_][]const u8{};

// ============================================================================
// 平台检测
// ============================================================================

// OS 别名表
const os_macos = [_][]const u8{ "darwin", "macos", "osx" };
const os_linux = [_][]const u8{ "linux", "gnu/linux" };
const os_windows = [_][]const u8{ "windows", "win32", "win64", "mingw" };

// 架构别名表
const arch_arm64 = [_][]const u8{ "arm64", "aarch64" };
const arch_x64 = [_][]const u8{ "x86_64", "amd64", "x64" };
const arch_x86 = [_][]const u8{ "x86", "386", "i386", "i686" };

// 不兼容 OS 表：匹配到这些 OS 别名则排除该资产
const other_os_for_macos = [_][]const u8{ "linux", "windows", "win32", "win64", "mingw", "android" };
const other_os_for_linux = [_][]const u8{ "darwin", "macos", "osx", "windows", "win32", "win64", "mingw", "android" };
const other_os_for_windows = [_][]const u8{ "darwin", "macos", "osx", "linux", "android" };

// 不兼容架构表
const other_arch_for_arm64 = [_][]const u8{
    "x86_64", "amd64", "x64", "x86", "386", "i386", "i686", "armv7", "armv6", "armhf", "arm32",
};
const other_arch_for_x64 = [_][]const u8{
    "arm64", "aarch64", "x86", "386", "i386", "i686", "armv7", "armv6", "armhf", "arm32",
};
const other_arch_for_x86 = [_][]const u8{
    "arm64", "aarch64", "x86_64", "amd64", "x64", "armv7", "armv6", "armhf", "arm32",
};

// macOS 通用二进制标识
const macos_generic = [_][]const u8{ "universal", "universal2" };

/// 根据当前编译目标和 CPU 架构返回平台特征
fn currentPlatformHints() PlatformHints {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{
                .label = "macos/arm64",
                .os = &os_macos,
                .arch = &arch_arm64,
                .other_os = &other_os_for_macos,
                .other_arch = &other_arch_for_arm64,
                .generic = &macos_generic,
            },
            .x86_64 => .{
                .label = "macos/x86_64",
                .os = &os_macos,
                .arch = &arch_x64,
                .other_os = &other_os_for_macos,
                .other_arch = &other_arch_for_x64,
                .generic = &macos_generic,
            },
            else => .{
                .label = "macos",
                .os = &os_macos,
                .arch = &empty_aliases,
                .other_os = &other_os_for_macos,
                .other_arch = &empty_aliases,
                .generic = &macos_generic,
            },
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => .{
                .label = "linux/arm64",
                .os = &os_linux,
                .arch = &arch_arm64,
                .other_os = &other_os_for_linux,
                .other_arch = &other_arch_for_arm64,
            },
            .x86_64 => .{
                .label = "linux/x86_64",
                .os = &os_linux,
                .arch = &arch_x64,
                .other_os = &other_os_for_linux,
                .other_arch = &other_arch_for_x64,
            },
            else => .{
                .label = "linux",
                .os = &os_linux,
                .arch = &empty_aliases,
                .other_os = &other_os_for_linux,
                .other_arch = &empty_aliases,
            },
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{
                .label = "windows/x86_64",
                .os = &os_windows,
                .arch = &arch_x64,
                .other_os = &other_os_for_windows,
                .other_arch = &other_arch_for_x64,
            },
            .x86 => .{
                .label = "windows/x86",
                .os = &os_windows,
                .arch = &arch_x86,
                .other_os = &other_os_for_windows,
                .other_arch = &other_arch_for_x86,
            },
            else => .{
                .label = "windows",
                .os = &os_windows,
                .arch = &empty_aliases,
                .other_os = &other_os_for_windows,
                .other_arch = &empty_aliases,
            },
        },
        else => .{
            .label = "current platform",
            .os = &empty_aliases,
            .arch = &empty_aliases,
            .other_os = &empty_aliases,
            .other_arch = &empty_aliases,
        },
    };
}

// ============================================================================
// 通用工具函数
// ============================================================================

/// 不区分大小写判断 haystack 是否包含 needle
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// 不区分大小写判断 haystack 是否包含 needles 中的任意一个
fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

/// 判断文件名是否为校验元数据文件（checksums/sha256/sig 等）
fn isMetadataFile(name: []const u8) bool {
    const exact = &[_][]const u8{ "checksums", "sha256", "sha512", "md5" };
    for (exact) |item| {
        if (std.ascii.eqlIgnoreCase(name, item)) return true;
    }
    const fragments = &[_][]const u8{ "checksum", "checksums", "sha256sum", "sha512sum", "md5sum" };
    if (containsAnyIgnoreCase(name, fragments)) return true;
    const suffixes = &[_][]const u8{ ".asc", ".sig", ".sha256", ".sha512", ".md5" };
    for (suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

/// 字节转 MB（用于下载速度显示）
fn fmtSize(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

/// 获取单调时钟毫秒值（用于计算下载耗时）
fn nowMonotonicMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// 获取 UTC ISO 8601 时间字符串（调用系统 date 命令）
fn nowUtcString(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" },
    });
    defer allocator.free(result.stderr);
    const len = if (result.stdout.len > 0 and result.stdout[result.stdout.len - 1] == '\n')
        result.stdout.len - 1
    else
        result.stdout.len;
    const out = try allocator.dupe(u8, result.stdout[0..len]);
    allocator.free(result.stdout);
    return out;
}

// ============================================================================
// 路径辅助函数
// ============================================================================

/// 获取 snag 基础目录 ~/.local/snag
fn getSnagBaseDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ home_dir, ".local", "snag" });
}

/// 获取状态文件路径 ~/.local/snag/state.json
fn getStatePath(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    const base = try getSnagBaseDir(allocator, home_dir);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "state.json" });
}

/// 获取默认安装目录 ~/.local/snag/bin
fn getInstallDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    const base = try getSnagBaseDir(allocator, home_dir);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "bin" });
}

/// 确保目录存在（忽略已存在错误）
fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

/// 确保父目录存在（用于文件写入前）
fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

// ============================================================================
// CLI / 参数解析
// ============================================================================

/// 打印帮助信息
fn usage() void {
    std.debug.print(
        \\snag — GitHub Release Asset Manager
        \\
        \\Usage:
        \\  snag install  <repo>               Install to ~/.local/snag/bin/
        \\  snag install  <repo> <dir>           Install to <dir> (binaries only)
        \\  snag install  <repo> -x [path]       Extract to path (keep all files)
        \\  snag download <repo> [path]        Download asset (or to path)
        \\  snag download <repo> -x [path]     Download + extract (or to path)
        \\  snag update   <repo>               Update installed repo
        \\  snag list                          List installed repos
        \\  snag remove   <repo>               Uninstall repo
        \\
        \\Options:
        \\  -v <tag>           Release tag (default: latest)
        \\  -m, -s <keyword>   Match keyword for asset name filtering
        \\  -os <value>        Platform/arch filter hint
        \\  -i, --interactive  Force interactive asset selection
        \\  -h, --help         Show this help message
        \\
        \\Short names: install=i, download=dl/d, update=up, list=ls, remove=rm
        \\
        \\Examples:
        \\  snag install blacktop/ida-mcp-rs
        \\  snag install -m ida-mcp blacktop/ida-mcp-rs -x ./out
        \\  snag download blacktop/ida-mcp-rs -x
        \\  snag update ida-mcp-rs
        \\  snag list
        \\
    , .{});
}

/// 判断参数是否像仓库标识（含 / 或 github.com）
fn looksLikeRepo(arg: []const u8) bool {
    return std.mem.findScalar(u8, arg, '/') != null or
        std.ascii.indexOfIgnoreCase(arg, "github.com") != null;
}

/// 判断字符串是否为选项标志（以 - 开头）
fn isFlag(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

/// 解析命令行参数
fn parseArgs(iter: *std.process.Args.Iterator) Args {
    var args = Args{};
    _ = iter.skip(); // 跳过程序名
    var want_path: bool = false; // 跟踪 -x 后的可选路径参数

    while (iter.next()) |arg| {
        // 处理 -x 后的路径参数
        if (want_path and !isFlag(arg)) {
            args.output = arg;
            want_path = false;
            continue;
        }
        want_path = false;

        // 选项解析
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            args.version = iter.next();
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "-s")) {
            args.match_keyword = iter.next();
        } else if (std.mem.eql(u8, arg, "-os")) {
            args.os_arch = iter.next();
        } else if (std.mem.eql(u8, arg, "-x")) {
            args.extract = true;
            want_path = true; // -x 后可跟可选路径
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            args.interactive = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            args.url = iter.next();
        } else if (std.mem.eql(u8, arg, "install") or std.mem.eql(u8, arg, "i")) {
            args.cmd = .install;
        } else if (std.mem.eql(u8, arg, "download") or std.mem.eql(u8, arg, "dl") or std.mem.eql(u8, arg, "d")) {
            args.cmd = .download;
        } else if (std.mem.eql(u8, arg, "update") or std.mem.eql(u8, arg, "upgrade") or std.mem.eql(u8, arg, "up")) {
            args.cmd = .update;
        } else if (std.mem.eql(u8, arg, "list") or std.mem.eql(u8, arg, "ls")) {
            args.cmd = .list;
        } else if (std.mem.eql(u8, arg, "remove") or std.mem.eql(u8, arg, "rm") or std.mem.eql(u8, arg, "uninstall") or std.mem.eql(u8, arg, "delete")) {
            args.cmd = .remove;
        } else if (args.url == null and looksLikeRepo(arg)) {
            args.url = arg; // 第一个像仓库的参数 → url
        } else if (args.cmd == .update or args.cmd == .remove) {
            if (args.url == null) args.url = arg; // update/remove 也可以接受仓库参数
        } else if (args.url != null and args.output == null and !isFlag(arg)) {
            args.output = arg; // 第二个非选项参数 → 输出目录
        }
    }
    return args;
}

/// 验证参数组合是否合法
fn validateArgs(args: Args) !void {
    if (args.help) {
        usage();
        return error.HelpRequested;
    }
    if (args.cmd == .list) return;
    if (args.cmd == .update and args.url == null) return; // update all 无需 url
    if (args.url == null) {
        usage();
        std.debug.print("\nerror: repository required\n", .{});
        return error.InvalidArgs;
    }
    if (args.cmd == .download) return;
    if (args.cmd == .update) {
        if (args.extract) {
            std.debug.print("error: update mode does not support -x\n", .{});
            return error.InvalidArgs;
        }
        return;
    }
    if (args.cmd == .remove) return;
}

// ============================================================================
// 仓库 / Release API
// ============================================================================

/// 去除路径末尾的斜杠
fn trimTrailingSlashes(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] == '/') {
        end -= 1;
    }
    return text[0..end];
}

/// 去除常见 GitHub URL 后缀 (/releases, /tags, .git 等)
fn stripRepoPath(text: []const u8) []const u8 {
    var t = text;
    const suffixes = &[_][]const u8{ "/releases", "/releases/", "/tags", "/tree", ".git" };
    for (suffixes) |suf| {
        if (std.ascii.endsWithIgnoreCase(t, suf)) {
            t = t[0 .. t.len - suf.len];
            break;
        }
    }
    return t;
}

/// 从 URL 或 owner/repo 字符串中解析出仓库标识
fn parseRepoSlug(repo: []const u8) !RepoSlug {
    var clean = trimTrailingSlashes(repo);
    clean = stripRepoPath(clean);
    clean = trimTrailingSlashes(clean);

    // 剥离 GitHub URL 前缀
    const prefixes = &[_][]const u8{
        "https://github.com/",
        "http://github.com/",
        "github.com/",
    };
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(clean, prefix)) {
            clean = clean[prefix.len..];
            break;
        }
    }
    if (clean.len > 0 and clean[0] == '/') clean = clean[1..];

    // 按 '/' 分割取前两部分作为 owner 和 name
    var parts = std.mem.splitScalar(u8, clean, '/');
    const owner = parts.next() orelse return error.InvalidRepo;
    const name = parts.next() orelse return error.InvalidRepo;
    if (owner.len == 0 or name.len == 0) return error.InvalidRepo;

    return .{ .owner = owner, .name = name };
}

/// 生成简单键 owner/name
fn slugKey(slug: RepoSlug, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ slug.owner, slug.name });
}

/// 生成资产键 owner/name@asset（用于同仓库多资产区分）
fn assetKey(slug: RepoSlug, asset_name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ slug.owner, slug.name, asset_name });
}

/// 构建 GitHub Releases API URL
fn repoApiUrl(allocator: std.mem.Allocator, repo: []const u8, version: ?[]const u8) ![]const u8 {
    const slug = try parseRepoSlug(repo);
    return if (version) |tag|
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/{s}", .{ slug.owner, slug.name, tag })
    else
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ slug.owner, slug.name });
}

/// 全局复用的 curl handle，避免每次请求重建 SSL 上下文
var curl_handle: ?*cURL.CURL = null;

fn getCurlHandle() *cURL.CURL {
    if (curl_handle) |h| return h;
    curl_handle = cURL.curl_easy_init().?;
    return curl_handle.?;
}

/// curlGet 的写回调上下文
const BodyCtx = struct {
    data: []u8,
    len: usize,
    allocator: std.mem.Allocator,

    fn append(ctx: *BodyCtx, bytes: []const u8) !void {
        if (ctx.len + bytes.len > ctx.data.len) {
            const new_cap = @max(ctx.data.len * 2, ctx.len + bytes.len + 4096);
            ctx.data = try ctx.allocator.realloc(ctx.data, new_cap);
        }
        @memcpy(ctx.data[ctx.len..][0..bytes.len], bytes);
        ctx.len += bytes.len;
    }

    fn toOwnedSlice(ctx: *BodyCtx) ![]u8 {
        if (ctx.len == 0) {
            ctx.allocator.free(ctx.data);
            ctx.data = &.{};
            return &.{};
        }
        const result = try ctx.allocator.realloc(ctx.data, ctx.len);
        ctx.data = &.{};
        return result;
    }
};

/// libcurl 写回调：接收响应数据追加到 BodyCtx
fn writeBodyCb(ptr: [*]u8, size: c_uint, nmemb: c_uint, userdata: ?*anyopaque) callconv(.c) c_uint {
    const total = size * nmemb;
    const ctx: *BodyCtx = @ptrCast(@alignCast(userdata));
    ctx.append(ptr[0..total]) catch return 0;
    return total;
}

/// 使用 libcurl 执行 HTTP GET，返回响应体（用于 API 调用，响应较小）
fn curlGet(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    _ = io;
    const url_z = try allocator.allocSentinel(u8, url.len, 0);
    @memcpy(url_z, url);
    defer allocator.free(url_z);

    var ctx = BodyCtx{
        .data = try allocator.alloc(u8, 8192),
        .len = 0,
        .allocator = allocator,
    };
    errdefer allocator.free(ctx.data);

    const curl = getCurlHandle();
    cURL.curl_easy_reset(curl);

    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_URL, url_z.ptr);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_USERAGENT, "snag/1.0");
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_TCP_NODELAY, @as(c_long, 1));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_BUFFERSIZE, @as(c_long, 128 * 1024));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_WRITEFUNCTION, &writeBodyCb);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_WRITEDATA, &ctx);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_TIMEOUT, @as(c_long, 30));

    var errbuf: [256]u8 = undefined;
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_ERRORBUFFER, &errbuf);

    const res = cURL.curl_easy_perform(curl);
    if (res != cURL.CURLE_OK) {
        std.debug.print("error: curl({d}): {s}\n", .{ res, std.mem.sliceTo(&errbuf, 0) });
        return error.HttpError;
    }

    return try ctx.toOwnedSlice();
}

/// 解析 GitHub Release JSON（先检测 API 错误响应）
fn parseRelease(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(Release) {
    // 先检测 GitHub API 错误（rate limit 等）
    var parsed_val = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch null;
    if (parsed_val) |*p| {
        defer p.deinit();
        if (p.value == .object) {
            if (p.value.object.get("message")) |msg| {
                if (msg == .string) {
                    std.debug.print("error: GitHub API: {s}\n", .{msg.string});
                    return error.HttpError;
                }
            }
        }
    }
    return std.json.parseFromSlice(Release, allocator, json, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("error: failed to parse API response: {}\n", .{err});
        return err;
    };
}

// ============================================================================
// 资产选择器 — 评分、筛选、去重、交互式选择
// ============================================================================

/// 根据平台特征对单个资产名评分，返回 null 表示不匹配当前平台
fn scoreAssetForPlatform(name: []const u8, hints: PlatformHints) ?u8 {
    if (isMetadataFile(name)) return null;

    const os_hit = containsAnyIgnoreCase(name, hints.os);
    const arch_hit = containsAnyIgnoreCase(name, hints.arch);
    const generic_hit = containsAnyIgnoreCase(name, hints.generic);

    // 排他性检查：命中了不兼容 OS 或架构则排除
    if (!os_hit and containsAnyIgnoreCase(name, hints.other_os)) return null;
    if (!arch_hit and containsAnyIgnoreCase(name, hints.other_arch) and !generic_hit) return null;

    var score: u8 = 1;
    if (os_hit) score += 4;
    if (arch_hit) score += 4;
    if (generic_hit) score += 2;
    return score;
}

/// 收集并评分所有候选资产，按评分降序排列
fn collectCandidates(
    allocator: std.mem.Allocator,
    release: Release,
    match_keyword: ?[]const u8,
    os_arch: ?[]const u8,
    platform: ?PlatformHints,
) ![]AssetCandidate {
    const max = release.assets.len;
    var list = try allocator.alloc(AssetCandidate, max);
    var count: usize = 0;
    errdefer allocator.free(list[0..count]);

    for (release.assets) |asset| {
        if (isMetadataFile(asset.name)) continue; // 跳过校验文件

        // 关键词筛选：资产名必须包含指定关键词
        if (match_keyword) |kw| {
            if (!containsIgnoreCase(asset.name, kw)) continue;
        }

        // OS 筛选：资产名必须包含指定 OS 标识
        if (os_arch) |oa| {
            if (!containsIgnoreCase(asset.name, oa)) continue;
        }

        var score: u8 = 1;
        var matches_platform = false;
        const matches_keyword = match_keyword != null;
        const matches_os_filter = os_arch != null;

        if (platform) |hints| {
            if (scoreAssetForPlatform(asset.name, hints)) |ps| {
                score = ps;
                matches_platform = true;
            } else {
                continue; // 不兼容当前平台 → 排除
            }
        } else {
            // 无外部平台筛选，但仍用自动检测评分排序
            const auto_hints = currentPlatformHints();
            if (scoreAssetForPlatform(asset.name, auto_hints)) |ps| {
                score = ps;
                matches_platform = true;
            }
        }

        // 用户主动指定的筛选条件额外加分
        if (match_keyword != null) score += 6;
        if (os_arch != null) score += 4;

        list[count] = .{
            .name = asset.name,
            .browser_download_url = asset.browser_download_url,
            .release_tag = release.tag_name,
            .score = score,
            .matches_platform = matches_platform,
            .matches_keyword = matches_keyword,
            .matches_os_filter = matches_os_filter,
        };
        count += 1;
    }

    const candidates = try allocator.realloc(list, count);
    // 按评分降序排列
    std.mem.sort(AssetCandidate, candidates, {}, struct {
        fn lt(_: void, a: AssetCandidate, b: AssetCandidate) bool {
            return a.score > b.score;
        }
    }.lt);
    return candidates;
}

/// 判断最高分候选是否明显唯一（无需交互选择）
fn isObviouslyUnique(candidates: []const AssetCandidate, args: Args) bool {
    if (candidates.len == 0) return false;
    if (candidates.len == 1) return true;
    if (candidates[0].score <= candidates[1].score) return false;
    if (args.match_keyword != null and !candidates[0].matches_keyword) return false;
    if (args.os_arch != null and !candidates[0].matches_os_filter) return false;
    return true;
}

/// 收集候选的匹配标签（用于 TUI 显示）
fn collectTags(c: AssetCandidate, buf: *[32]u8) []const u8 {
    var pos: usize = 0;
    if (c.matches_platform) {
        const tag = "[platform] ";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    if (c.matches_keyword) {
        const tag = "[keyword] ";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    if (c.matches_os_filter) {
        const tag = "[os] ";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    return buf[0..pos];
}

// ============================================================================
// 终端交互式选择（原始模式键盘输入）
// ============================================================================

/// 键盘按键类型
const Key = union(enum) {
    char: u8,
    up,
    down,
    enter,
    esc,
    tab,
    backspace,
};

/// 读取单个按键（处理 ANSI 转义序列）
fn readKey() !Key {
    var buf: [3]u8 = undefined;
    const n = try std.posix.read(0, &buf);
    if (n == 0) return error.Eof;
    if (buf[0] == '\x1b') {
        if (n > 1 and buf[1] == '[') {
            if (n > 2) {
                return switch (buf[2]) {
                    'A' => .up,
                    'B' => .down,
                    else => .esc,
                };
            }
        }
        return .esc;
    }
    if (buf[0] == '\r' or buf[0] == '\n') return .enter;
    if (buf[0] == '\t') return .tab;
    if (buf[0] == 127 or buf[0] == 8) return .backspace;
    return .{ .char = buf[0] };
}

/// 原始终端模式管理器（进入时关闭回显和行缓冲，退出时恢复）
const RawTerm = if (builtin.os.tag == .windows)
    struct {
        fn enter() !@This() {
            return .{};
        }
        fn exit(_: *@This()) void {}
    }
else
    struct {
        orig: std.posix.termios,

        fn enter() !@This() {
            const orig = try std.posix.tcgetattr(0);
            var raw = orig;
            raw.lflag.ECHO = false; // 关闭回显
            raw.lflag.ICANON = false; // 关闭行缓冲（字符即时读取）
            raw.cc[6] = 1; // VMIN
            raw.cc[5] = 0; // VTIME
            try std.posix.tcsetattr(0, .NOW, raw);
            return .{ .orig = orig };
        }

        fn exit(self: *@This()) void {
            std.posix.tcsetattr(0, .NOW, self.orig) catch {};
        }
    };

/// 绘制交互式候选列表（使用 ANSI 控制码原地刷新）
fn drawList(candidates: []const AssetCandidate, cursor: usize, filter: []const u8, prev_lines: *usize) void {
    // 光标上移 prev_lines 行并回到行首
    if (prev_lines.* > 0) {
        std.debug.print("\x1b[{}A\r", .{prev_lines.*});
    }
    // 清除光标到屏幕底部
    std.debug.print("\x1b[0J", .{});
    var lines: usize = 0;
    std.debug.print("  type to filter  ↑↓ move  enter select  esc quit\n", .{});
    lines += 1;
    if (candidates.len == 0) {
        if (filter.len > 0) {
            std.debug.print("  (no matches)\n", .{});
            lines += 1;
        }
    } else {
        const max_show: usize = 10;
        // 计算滚动窗口起始位置
        const start = blk: {
            if (candidates.len <= max_show) break :blk @as(usize, 0);
            if (cursor < max_show / 2) break :blk @as(usize, 0);
            if (cursor >= candidates.len - max_show / 2) break :blk candidates.len - max_show;
            break :blk cursor - max_show / 2;
        };
        if (start > 0) {
            std.debug.print("     ...\n", .{});
            lines += 1;
        }
        const end = @min(start + max_show, candidates.len);
        for (candidates[start..end], start..) |c, i| {
            if (i == cursor) {
                // 反色高亮当前选中行
                std.debug.print("  \x1b[7m ▶ {s} \x1b[0m\n", .{c.name});
            } else {
                std.debug.print("     {s}\n", .{c.name});
            }
            lines += 1;
        }
        if (end < candidates.len) {
            std.debug.print("     ...\n", .{});
            lines += 1;
        }
        // 显示选中候选的版本号和标签
        var tag_buf: [32]u8 = undefined;
        const tags = collectTags(candidates[cursor], &tag_buf);
        std.debug.print("\n  {s} (score: {d}) {s}\n", .{ candidates[cursor].release_tag, candidates[cursor].score, tags });
        lines += 2;
    }
    // 输入提示行（不换行，光标停在 '>' 后面）
    std.debug.print("  > {s}\x1b[K", .{filter});
    prev_lines.* = lines;
}

/// 对候选列表应用文本筛选
fn applyFilter(
    allocator: std.mem.Allocator,
    all_candidates: []const AssetCandidate,
    filter: []const u8,
    filtered: *[]AssetCandidate,
    filtered_len: *usize,
    cursor: *usize,
) !void {
    if (filter.len == 0) {
        // 无筛选时恢复全部候选
        allocator.free(filtered.*);
        filtered.* = try allocator.alloc(AssetCandidate, all_candidates.len);
        @memcpy(filtered.*, all_candidates);
        filtered_len.* = all_candidates.len;
        return;
    }
    var new_f = try allocator.alloc(AssetCandidate, all_candidates.len);
    var cnt: usize = 0;
    for (all_candidates) |c| {
        if (containsIgnoreCase(c.name, filter)) {
            new_f[cnt] = c;
            cnt += 1;
        }
    }
    allocator.free(filtered.*);
    filtered.* = new_f;
    filtered_len.* = cnt;
    if (cursor.* >= cnt and cnt > 0) cursor.* = cnt - 1;
}

/// 交互式资产选择器：返回在原列表中的索引，取消则返回 null
fn interactiveSelect(
    allocator: std.mem.Allocator,
    all_candidates: []const AssetCandidate,
) !?usize {
    // Windows 下不支持原始终端模式
    if (builtin.os.tag == .windows) {
        if (all_candidates.len > 0) return 0;
        return null;
    }
    if (all_candidates.len == 0) {
        std.debug.print("No candidates to select from.\n", .{});
        return null;
    }

    var filtered = try allocator.alloc(AssetCandidate, all_candidates.len);
    @memcpy(filtered, all_candidates);
    var filtered_len: usize = all_candidates.len;
    defer allocator.free(filtered);

    // 进入原始终端模式
    var term = try RawTerm.enter();
    defer term.exit(); // 离开函数时恢复终端设置

    var cursor: usize = 0;
    var filter_buf: [256]u8 = undefined;
    var filter_len: usize = 0;
    var prev_lines: usize = 0;

    while (true) {
        drawList(filtered[0..filtered_len], cursor, filter_buf[0..filter_len], &prev_lines);

        const key = readKey() catch break;

        switch (key) {
            .esc => {
                std.debug.print("\n", .{});
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    try applyFilter(allocator, all_candidates, filter_buf[0..filter_len], &filtered, &filtered_len, &cursor);
                }
            },
            .char => |c| {
                if (filter_len < filter_buf.len) {
                    filter_buf[filter_len] = c;
                    filter_len += 1;
                    try applyFilter(allocator, all_candidates, filter_buf[0..filter_len], &filtered, &filtered_len, &cursor);
                }
            },
            .up => {
                if (cursor > 0) cursor -= 1;
            },
            .down => {
                if (cursor + 1 < filtered_len) cursor += 1;
            },
            .enter => {
                if (filtered_len == 0) continue;
                const sel = filtered[cursor];
                // 在原始列表中查找匹配索引
                for (all_candidates, 0..) |c, i| {
                    if (std.mem.eql(u8, c.name, sel.name) and
                        std.mem.eql(u8, c.browser_download_url, sel.browser_download_url))
                    {
                        return i;
                    }
                }
                return cursor;
            },
            else => {},
        }
    }
    std.debug.print("\n", .{});
    return null;
}

// ============================================================================
// 状态文件持久化
// ============================================================================

/// 加载状态文件 state.json，不存在则返回空状态
fn loadState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8) !StateFile {
    const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, @enumFromInt(1048576)) catch |err| switch (err) {
        error.FileNotFound => return StateFile{
            .records = std.StringHashMap(InstallRecord).init(allocator),
            .allocator = allocator,
        },
        else => |e| {
            std.debug.print("error: cannot read '{s}': {}\n", .{ state_path, e });
            return e;
        },
    };
    defer allocator.free(json_bytes);

    // 解析 JSON，损坏时报错退出
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch |err| {
        std.debug.print("error: '{s}' is corrupted: {}\n", .{ state_path, err });
        return err;
    };
    defer parsed.deinit();

    var records = std.StringHashMap(InstallRecord).init(allocator);
    errdefer {
        var it = records.iterator();
        while (it.next()) |entry| {
            freeRecordFields(allocator, entry.value_ptr);
        }
        records.deinit();
    }

    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const rec = try parseInstallRecord(allocator, entry.value_ptr.*);
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            try records.put(key, rec);
        }
    }

    return StateFile{ .records = records, .allocator = allocator };
}

/// 从 JSON Value 解析单条安装记录
fn parseInstallRecord(allocator: std.mem.Allocator, value: std.json.Value) !InstallRecord {
    if (value != .object) return error.InvalidStateFormat;
    const obj = value.object;

    return InstallRecord{
        .repo_url = try allocator.dupe(u8, getStringField(obj, "repo_url") orelse return error.InvalidStateFormat),
        .repo_slug = try allocator.dupe(u8, getStringField(obj, "repo_slug") orelse return error.InvalidStateFormat),
        .install_dir = try allocator.dupe(u8, getStringField(obj, "install_dir") orelse return error.InvalidStateFormat),
        .installed_version = try allocator.dupe(u8, getStringField(obj, "installed_version") orelse return error.InvalidStateFormat),
        .selected_asset_name = try allocator.dupe(u8, getStringField(obj, "selected_asset_name") orelse return error.InvalidStateFormat),
        .selected_download_url = try allocator.dupe(u8, getStringField(obj, "selected_download_url") orelse return error.InvalidStateFormat),
        .install_mode = try allocator.dupe(u8, getStringField(obj, "install_mode") orelse return error.InvalidStateFormat),
        // install_type 兼容旧值：bin→lean, custom→full
        .install_type = try allocator.dupe(u8, blk: {
            const raw = getStringField(obj, "install_type") orelse break :blk "lean";
            if (std.mem.eql(u8, raw, "bin")) break :blk "lean";
            if (std.mem.eql(u8, raw, "custom")) break :blk "full";
            break :blk raw;
        }),
        .installed_files = try parseInstalledFiles(allocator, obj),
        .selected_match_keyword = if (getStringField(obj, "selected_match_keyword")) |kw| try allocator.dupe(u8, kw) else null,
        .selected_os_arch = if (getStringField(obj, "selected_os_arch")) |osa| try allocator.dupe(u8, osa) else null,
        .installed_at = try allocator.dupe(u8, getStringField(obj, "installed_at") orelse return error.InvalidStateFormat),
    };
}

/// 解析 installed_files 字段（兼容 JSON 数组和旧版逗号分隔字符串）
fn parseInstalledFiles(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const []const u8 {
    const val = obj.get("installed_files") orelse return &.{};

    const arr = val.array;
    const files = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        files[i] = try allocator.dupe(u8, item.string);
    }
    return files;

}

/// 从 JSON 对象中安全提取字符串字段
fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

/// 释放 InstallRecord 中所有动态内存
fn freeRecordFields(allocator: std.mem.Allocator, rec: *InstallRecord) void {
    allocator.free(rec.repo_url);
    allocator.free(rec.repo_slug);
    allocator.free(rec.install_dir);
    allocator.free(rec.installed_version);
    allocator.free(rec.selected_asset_name);
    allocator.free(rec.selected_download_url);
    allocator.free(rec.install_mode);
    allocator.free(rec.install_type);
    for (rec.installed_files) |f| allocator.free(f);
    allocator.free(rec.installed_files);
    if (rec.selected_match_keyword) |kw| allocator.free(kw);
    if (rec.selected_os_arch) |os| allocator.free(os);
    allocator.free(rec.installed_at);
}

/// 将状态序列化为 JSON 并写入文件
fn saveState(state: *const StateFile, io: std.Io, state_path: []const u8) !void {
    const gpa = state.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");

    var it = state.records.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(gpa, ",\n");
        first = false;
        const rec = entry.value_ptr;
        try buf.print(gpa,
            \\  "{s}": {{
            \\    "repo_url": "{s}",
            \\    "repo_slug": "{s}",
            \\    "install_dir": "{s}",
            \\    "installed_version": "{s}",
            \\    "selected_asset_name": "{s}",
            \\    "selected_download_url": "{s}",
            \\    "install_mode": "{s}",
            \\    "install_type": "{s}",
            \\    "installed_files": [
        , .{
            entry.key_ptr.*,
            rec.repo_url,
            rec.repo_slug,
            rec.install_dir,
            rec.installed_version,
            rec.selected_asset_name,
            rec.selected_download_url,
            rec.install_mode,
            rec.install_type,
        });
        for (rec.installed_files, 0..) |f, i| {
            if (i > 0) try buf.appendSlice(gpa, ", ");
            try buf.print(gpa, "\"{s}\"", .{f});
        }
        try buf.appendSlice(gpa, "]");

        if (rec.selected_match_keyword) |kw| {
            try buf.print(gpa, ",\n    \"selected_match_keyword\": \"{s}\"", .{kw});
        } else {
            try buf.appendSlice(gpa, ",\n    \"selected_match_keyword\": null");
        }

        if (rec.selected_os_arch) |osa| {
            try buf.print(gpa, ",\n    \"selected_os_arch\": \"{s}\"", .{osa});
        } else {
            try buf.appendSlice(gpa, ",\n    \"selected_os_arch\": null");
        }

        try buf.print(gpa, ",\n    \"installed_at\": \"{s}\"\n  }}", .{rec.installed_at});
    }

    try buf.appendSlice(gpa, "\n}\n");

    try ensureParentDir(io, state_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = buf.items });
}

/// 插入或更新记录
fn upsertRecord(state: *StateFile, key: []const u8, record: InstallRecord) !void {
    if (state.records.getEntry(key)) |existing| {
        // 释放旧值并替换
        freeRecordFields(state.allocator, existing.value_ptr);
        existing.value_ptr.* = record;
    } else {
        const key_dup = try state.allocator.dupe(u8, key);
        try state.records.put(key_dup, record);
    }
}

/// 按键查找记录
fn findRecord(state: *const StateFile, key: []const u8) ?InstallRecord {
    return state.records.get(key);
}

/// 删除记录关联的所有文件/目录
fn removeRecordFiles(allocator: std.mem.Allocator, io: std.Io, rec: *const InstallRecord) void {
    if (rec.installed_files.len == 0) {
        // 无文件列表则整体删除安装目录
        std.Io.Dir.cwd().deleteTree(io, rec.install_dir) catch {};
    } else {
        // 逐一删除记录中的文件和目录
        for (rec.installed_files) |name| {
            const fp = std.fs.path.join(allocator, &.{ rec.install_dir, name }) catch continue;
            defer allocator.free(fp);
            if (std.Io.Dir.cwd().openDir(io, fp, .{})) |d| {
                d.close(io);
                std.Io.Dir.cwd().deleteTree(io, fp) catch {};
            } else |_| {
                std.Io.Dir.cwd().deleteFile(io, fp) catch {};
            }
        }
    }
}

/// 查找某仓库在状态中的所有记录键
fn findRepoRecords(state: *const StateFile, repo_slug: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = state.records.iterator();
    while (it.next()) |entry| {
        const stored = entry.value_ptr.repo_slug;
        // repo_slug 不带 @，直接比较或剥离 @ 后比较（兼容旧数据）
        const base = if (std.mem.findScalar(u8, stored, '@')) |at| stored[0..at] else stored;
        if (std.mem.eql(u8, base, repo_slug)) {
            try list.append(state.allocator, entry.key_ptr.*);
        }
    }
    return list.toOwnedSlice(state.allocator);
}

/// 将简单键迁移为 @asset 格式（同仓库添加不同资产时触发）
fn migrateRecordKey(allocator: std.mem.Allocator, state: *StateFile, old_key: []const u8, repo_slug: []const u8) !void {
    if (state.records.fetchRemove(old_key)) |kv| {
        const rec = kv.value;
        const new_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ repo_slug, rec.selected_asset_name });
        errdefer allocator.free(new_key);
        try state.records.put(new_key, rec);
        allocator.free(kv.key);
    }
}

/// 通过仓库短名称查找记录键（用于 remove/update 简写）
fn findByShortName(state: *const StateFile, short: []const u8) ![]const u8 {
    var match: ?[]const u8 = null;
    var it = state.records.iterator();
    while (it.next()) |entry| {
        const slug = entry.value_ptr.repo_slug;
        if (std.mem.endsWith(u8, slug, short)) {
            // 必须是完整名称匹配（最后一个 / 之后的部分）
            if (std.mem.lastIndexOfScalar(u8, slug, '/')) |slash| {
                if (std.ascii.eqlIgnoreCase(slug[slash + 1 ..], short)) {
                    if (match != null) {
                        std.debug.print("error: '{s}' matches multiple repos: {s}, {s}\n", .{ short, match.?, entry.key_ptr.* });
                        return error.AmbiguousMatch;
                    }
                    match = entry.key_ptr.*;
                }
            }
        }
    }
    return match orelse error.NoInstallRecord;
}

// ============================================================================
// Update 专用匹配逻辑
// ============================================================================

const ScoredIdx = struct { idx: usize, score: u8 };

/// 更新时自动匹配候选：优先精确资产名，其次关键词+OS 评分
fn tryUpdateMatch(
    candidates: []const AssetCandidate,
    record: InstallRecord,
) ?usize {
    if (candidates.len == 0) return null;

    // 1. 优先精确资产名匹配（不区分大小写）
    for (candidates, 0..) |c, i| {
        if (std.ascii.eqlIgnoreCase(c.name, record.selected_asset_name)) {
            return i;
        }
    }

    // 2. 使用存储的关键词和 OS 进行评分匹配
    var scored_buf: [64]ScoredIdx = undefined;
    var scored_count: usize = 0;

    for (candidates, 0..) |c, i| {
        var score: u8 = 1;
        if (record.selected_match_keyword) |kw| {
            if (containsIgnoreCase(c.name, kw)) score += 6 else continue;
        }
        if (record.selected_os_arch) |osa| {
            if (containsIgnoreCase(c.name, osa)) score += 4 else continue;
        }
        if (scored_count < scored_buf.len) {
            scored_buf[scored_count] = .{ .idx = i, .score = score };
            scored_count += 1;
        }
    }

    const scored = scored_buf[0..scored_count];
    if (scored.len == 1) return scored[0].idx;
    if (scored.len >= 2) {
        std.mem.sort(ScoredIdx, scored, {}, struct {
            fn lt(_: void, a: ScoredIdx, b: ScoredIdx) bool {
                return a.score > b.score;
            }
        }.lt);
        if (scored[0].score > scored[1].score) {
            return scored[0].idx;
        }
    }

    return null;
}

// ============================================================================
// HTTP 下载 (curl)
// ============================================================================

/// 下载上下文：传递给 libcurl 回调
const DlCtx = struct {
    file: std.Io.File,
    io: std.Io,
    start: i64,
    tick_count: usize = 0,
};

/// libcurl 写回调：将数据写入文件
fn writeFileCb(ptr: [*]u8, size: c_uint, nmemb: c_uint, userdata: ?*anyopaque) callconv(.c) c_uint {
    const total = size * nmemb;
    const ctx: *DlCtx = @ptrCast(@alignCast(userdata));
    ctx.file.writeStreamingAll(ctx.io, ptr[0..total]) catch return 0;
    return total;
}

/// libcurl 进度回调：实时显示下载速度和大小
fn xferInfoCb(clientp: ?*anyopaque, dltotal: cURL.curl_off_t, dlnow: cURL.curl_off_t, ultotal: cURL.curl_off_t, ulnow: cURL.curl_off_t) callconv(.c) c_int {
    const ctx: *DlCtx = @ptrCast(@alignCast(clientp));
    _ = dltotal; _ = ultotal; _ = ulnow;
    if (dlnow == 0) return 0;
    // 每 ~50 次回调才检查一次时间，减少系统调用
    ctx.tick_count += 1;
    if (ctx.tick_count % 50 != 0) return 0;
    const now = nowMonotonicMs(ctx.io);
    const mb = fmtSize(@intCast(dlnow));
    const elapsed = @as(f64, @floatFromInt(now - ctx.start)) / 1000.0;
    if (elapsed > 1) {
        const speed = mb / elapsed;
        std.debug.print("\r  {d:.2} MB  {d:.1} MB/s\x1b[K", .{ mb, speed });
    } else {
        std.debug.print("\r  {d:.2} MB  ...\x1b[K", .{mb});
    }
    return 0;
}

/// 使用 libcurl 下载文件到指定路径（先写临时文件，成功后原子重命名，带进度显示）
fn curlDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    path: []const u8,
) !void {
    const label = std.fs.path.basename(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.snag-tmp", .{label});
    defer allocator.free(tmp_path);

    try ensureParentDir(io, path);
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer file.close(io);

    var ctx = DlCtx{
        .file = file,
        .io = io,
        .start = nowMonotonicMs(io),
    };

    const url_z = try allocator.allocSentinel(u8, url.len, 0);
    @memcpy(url_z, url);
    defer allocator.free(url_z);

    const curl = getCurlHandle();
    cURL.curl_easy_reset(curl);

    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_URL, url_z.ptr);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_USERAGENT, "snag/1.0");
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_BUFFERSIZE, @as(c_long, 512 * 1024));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_TCP_NODELAY, @as(c_long, 1));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_WRITEFUNCTION, &writeFileCb);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_WRITEDATA, &ctx);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_TIMEOUT, @as(c_long, 600));
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_XFERINFOFUNCTION, &xferInfoCb);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_XFERINFODATA, &ctx);
    _ = cURL.curl_easy_setopt(curl, cURL.CURLOPT_NOPROGRESS, @as(c_long, 0));

    const res = cURL.curl_easy_perform(curl);
    if (res != cURL.CURLE_OK) {
        std.debug.print("\nerror: download failed: {s}\n", .{cURL.curl_easy_strerror(res)});
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return error.HttpError;
    }

    // 完成行
    const size = (std.Io.Dir.cwd().statFile(io, tmp_path, .{}) catch return).size;
    std.debug.print("\r  {s}: {d:.2} MB\n", .{ label, fmtSize(size) });

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

// ============================================================================
// 解压
// ============================================================================

/// 运行外部命令并检查返回状态
fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        const name = if (argv.len > 0) argv[0] else "command";
        if (err == error.FileNotFound) {
            std.debug.print("error: '{s}' not found (is it installed?)\n", .{name});
        } else {
            std.debug.print("error: failed to run '{s}': {}\n", .{ name, err });
        }
        return err;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (switch (res.term) {
        .exited => |code| code != 0,
        else => true,
    }) {
        if (res.stderr.len > 0) {
            std.debug.print("error: extraction failed: {s}\n", .{res.stderr});
        } else {
            std.debug.print("error: extraction exited unsuccessfully\n", .{});
        }
        return error.CommandFailed;
    }
}

/// 从 URL 路径提取文件名（去除查询参数和片段）
fn basenameFromUrl(url: []const u8) []const u8 {
    const query_pos = std.mem.findScalar(u8, url, '?') orelse url.len;
    const fragment_pos = std.mem.findScalar(u8, url, '#') orelse url.len;
    const end = @min(query_pos, fragment_pos);
    return std.fs.path.basename(url[0..end]);
}

/// 判断文件名是否为可解压的归档格式
fn isCompressedFormat(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".tar.gz") or
        std.ascii.endsWithIgnoreCase(name, ".tar.xz") or
        std.ascii.endsWithIgnoreCase(name, ".tgz") or
        std.ascii.endsWithIgnoreCase(name, ".zip") or
        std.ascii.endsWithIgnoreCase(name, ".xz");
}

/// 单层目录展平：如果解压后目录内只有一个子目录且没有文件，将子目录内容上移
fn flattenSingleDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var subdir_name: ?[]const u8 = null;
    var file_count: usize = 0;
    var iter = dir.iterate();
    defer if (subdir_name) |n| allocator.free(n);
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (subdir_name != null) return; // 多个目录 → 不展平
            subdir_name = try allocator.dupe(u8, entry.name);
        } else {
            file_count += 1;
        }
    }
    // 只有恰好 1 个目录且 0 个文件时才展平
    if (subdir_name == null or file_count > 0) return;

    const sub_path = try std.fs.path.join(allocator, &.{ dir_path, subdir_name.? });
    defer allocator.free(sub_path);

    // 将子目录中所有内容移到上层
    var sub = try std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true });
    defer sub.close(io);
    var sub_iter = sub.iterate();
    while (try sub_iter.next(io)) |entry| {
        const src = try std.fs.path.join(allocator, &.{ sub_path, entry.name });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(dst);
        try std.Io.Dir.rename(.cwd(), src, .cwd(), dst, io);
    }
    // 删除空子目录
    try std.Io.Dir.cwd().deleteDir(io, sub_path);
}

/// 解压归档文件到目标目录
fn extract(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive: []const u8,
    out_dir: ?[]const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const target = out_dir orelse ".";

    if (out_dir) |dir| {
        cwd.createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }

    if (std.ascii.endsWithIgnoreCase(archive, ".tar.xz")) {
        const argv = if (out_dir) |dir|
            &[_][]const u8{ "tar", "-xJf", archive, "-C", dir }
        else
            &[_][]const u8{ "tar", "-xJf", archive };
        try runCommand(allocator, io, argv);
        try cwd.deleteFile(io, archive);
        if (out_dir != null) try flattenSingleDir(allocator, io, target);
    } else if (std.ascii.endsWithIgnoreCase(archive, ".tar.gz") or std.ascii.endsWithIgnoreCase(archive, ".tgz")) {
        const argv = if (out_dir) |dir|
            &[_][]const u8{ "tar", "-xzf", archive, "-C", dir }
        else
            &[_][]const u8{ "tar", "-xzf", archive };
        try runCommand(allocator, io, argv);
        try cwd.deleteFile(io, archive);
        if (out_dir != null) try flattenSingleDir(allocator, io, target);
    } else if (std.ascii.endsWithIgnoreCase(archive, ".zip")) {
        if (out_dir) |dir| {
            try runCommand(allocator, io, &.{ "unzip", "-o", archive, "-d", dir });
        } else {
            try runCommand(allocator, io, &.{ "unzip", "-o", archive });
        }
        try cwd.deleteFile(io, archive);
        if (out_dir != null) try flattenSingleDir(allocator, io, target);
    } else if (std.ascii.endsWithIgnoreCase(archive, ".xz")) {
        try runCommand(allocator, io, &.{ "xz", "-d", archive });
        if (out_dir) |dir| {
            const extracted = archive[0 .. archive.len - 3];
            const name = std.fs.path.basename(extracted);
            const dest = try std.fs.path.join(allocator, &.{ dir, name });
            defer allocator.free(dest);
            try std.Io.Dir.rename(cwd, extracted, cwd, dest, io);
        }
    } else {
        std.debug.print("Unknown archive format, skipping extraction\n", .{});
    }
}

// ============================================================================
// 安装逻辑
// ============================================================================

/// 判断文件是否为应清理的杂项文件（README、LICENSE 等）
fn isJunkFile(name: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    const lower = lower_buf[0..@min(name.len, 256)];
    for (name[0..lower.len], 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    const exact = &[_][]const u8{
        "readme",          "readme.md",          "readme.txt",   "readme.markdown",
        "license",         "license.md",         "license.txt",  "changelog",
        "changelog.md",    "changelog.txt",      "contributing", "contributing.md",
        "code_of_conduct", "code_of_conduct.md", "security",     "security.md",
        "authors",         "authors.txt",        "copyright",    "notice",
    };
    for (exact) |e| {
        if (std.mem.eql(u8, lower, e)) return true;
    }
    if (std.mem.endsWith(u8, lower, ".md")) return true;
    if (std.mem.endsWith(u8, lower, ".markdown")) return true;
    if (std.mem.endsWith(u8, lower, ".txt")) return true;
    if (std.mem.endsWith(u8, lower, ".1")) return true;
    if (std.mem.endsWith(u8, lower, ".5")) return true;
    if (std.mem.endsWith(u8, lower, ".8")) return true;
    return false;
}

/// 清理安装目录中的杂项文件（lean 模式执行）
fn cleanInstallDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isJunkFile(entry.name)) {
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full_path);
            std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
                std.debug.print("  (skip: could not delete {s}: {})\n", .{ entry.name, err });
            };
        }
    }
}

/// 下载资产并解压（如果是归档），lean 模式还会清理杂项文件
fn installAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: AssetCandidate,
    install_dir: []const u8,
    clean_junk: bool,
) !void {
    try ensureDir(io, install_dir);

    const basename = basenameFromUrl(candidate.browser_download_url);
    const tmp_path = try std.fs.path.join(allocator, &.{ trimTrailingSlashes(install_dir), basename });
    defer allocator.free(tmp_path);

    std.debug.print("Downloading: {s}\n", .{candidate.browser_download_url});
    try curlDownload(allocator, io, candidate.browser_download_url, tmp_path);

    const is_archive = isCompressedFormat(basename);

    if (is_archive) {
        std.debug.print("Extracting to: {s}\n", .{install_dir});
        extract(allocator, io, tmp_path, install_dir) catch |err| {
            std.debug.print("error: extraction failed, removing partial download\n", .{});
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return err;
        };
        if (clean_junk) {
            std.debug.print("Cleaning up junk files...\n", .{});
            try cleanInstallDir(allocator, io, install_dir);
        }
    }

    std.debug.print("Installed: {s}\n", .{install_dir});
}

// ============================================================================
// 主流程
// ============================================================================

/// 更新单个已安装的仓库
fn updateOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *StateFile,
    state_path: []const u8,
    repo_key: []const u8,
    args: Args,
) !void {
    const record = findRecord(state, repo_key) orelse return error.NoInstallRecord;
    std.debug.print("Checking {s}...\n", .{repo_key});

    const api_url = repoApiUrl(allocator, record.repo_url, args.version) catch
        try repoApiUrl(allocator, repo_key, args.version);
    defer allocator.free(api_url);

    const json = try curlGet(allocator, io, api_url);
    defer allocator.free(json);

    const parsed = try parseRelease(allocator, json);
    defer parsed.deinit();
    const release = parsed.value;

    const auto_detect = args.os_arch == null and record.selected_os_arch == null;
    const platform = if (auto_detect) currentPlatformHints() else null;
    const candidates = try collectCandidates(
        allocator,
        release,
        if (args.match_keyword) |_| args.match_keyword else record.selected_match_keyword,
        if (args.os_arch) |_| args.os_arch else record.selected_os_arch,
        platform,
    );
    defer allocator.free(candidates);

    const selected_idx = tryUpdateMatch(candidates, record);
    if (selected_idx) |idx| {
        const c = candidates[idx];
        std.debug.print("  {s} => {s}\n", .{ record.installed_version, c.release_tag });
        if (std.mem.eql(u8, record.installed_version, c.release_tag)) {
            std.debug.print("  (already up to date)\n", .{});
            return;
        }
        const do_clean = std.mem.eql(u8, record.install_type, "lean");
        try installAsset(allocator, io, c, record.install_dir, do_clean);
        try writeInstallRecord(allocator, io, state, state_path, repo_key, args, c, record.install_dir, record.install_type, &.{});
        return;
    }

    if (args.interactive) {
        std.debug.print("  Auto-match failed, entering interactive mode...\n", .{});
        const idx = try interactiveSelect(allocator, candidates) orelse return;
        const c = candidates[idx];
        const do_clean = std.mem.eql(u8, record.install_type, "lean");
        try installAsset(allocator, io, c, record.install_dir, do_clean);
        try writeInstallRecord(allocator, io, state, state_path, repo_key, args, c, record.install_dir, record.install_type, &.{});
        return;
    }

    return error.AmbiguousMatch;
}

/// 决策是否需要交互选择，并返回选中的候选索引
fn selectAssetIdx(
    allocator: std.mem.Allocator,
    candidates: []AssetCandidate,
    args: Args,
) !?usize {
    if (candidates.len == 0) return null;
    if (args.interactive) {
        return try interactiveSelect(allocator, candidates);
    }
    if (isObviouslyUnique(candidates, args)) return 0;
    // 多个候选且无法自动判断 → 自动进入交互模式
    std.debug.print("Multiple candidates found, entering interactive mode...\n", .{});
    return try interactiveSelect(allocator, candidates);
}

/// 获取 Release 信息并选择资产（install/download 共用）
fn fetchAndSelect(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    auto_platform: bool,
) !?AssetCandidate {
    std.debug.print("Fetching release info...\n", .{});
    const api_url = try repoApiUrl(allocator, args.url.?, args.version);
    defer allocator.free(api_url);

    const json = try curlGet(allocator, io, api_url);
    defer allocator.free(json);

    const parsed = try parseRelease(allocator, json);
    defer parsed.deinit();
    const release = parsed.value;

    const platform = if (auto_platform and args.os_arch == null) currentPlatformHints() else null;
    const candidates = try collectCandidates(allocator, release, args.match_keyword, args.os_arch, platform);
    defer allocator.free(candidates);

    if (candidates.len == 0) {
        std.debug.print("No matching assets found.\n", .{});
        if (platform) |p| std.debug.print("  platform: {s}\n", .{p.label});
        return null;
    }

    const idx = (try selectAssetIdx(allocator, candidates, args)) orelse return null;
    std.debug.print("\n", .{});
    return AssetCandidate{
        .name = try allocator.dupe(u8, candidates[idx].name),
        .browser_download_url = try allocator.dupe(u8, candidates[idx].browser_download_url),
        .release_tag = try allocator.dupe(u8, candidates[idx].release_tag),
        .score = candidates[idx].score,
        .matches_platform = candidates[idx].matches_platform,
        .matches_keyword = candidates[idx].matches_keyword,
        .matches_os_filter = candidates[idx].matches_os_filter,
    };
}

/// 解析仓库标识键（处理 owner/name、URL、@asset 语法、短名称）
fn resolveRepoKey(
    allocator: std.mem.Allocator,
    state: *const StateFile,
    url: []const u8,
) ![]const u8 {
    // 处理 @asset 语法: owner/name@asset
    if (std.mem.findScalar(u8, url, '@')) |at_pos| {
        const repo_part = url[0..at_pos];
        const slug = try parseRepoSlug(repo_part);
        const key = try assetKey(slug, url[at_pos + 1 ..], allocator);
        if (state.records.get(key) != null) return key;
        allocator.free(key);
        return error.NoInstallRecord;
    }
    // 尝试作为 owner/repo 或完整 URL 解析
    if (parseRepoSlug(url)) |slug| {
        // 先查简单键（单资产记录）
        const simple_key = try slugKey(slug, allocator);
        if (state.records.get(simple_key) != null) return simple_key;
        allocator.free(simple_key);
        // 再查多资产键
        const keys = try findRepoRecords(state, try slugKey(slug, allocator));
        if (keys.len > 0) {
            std.debug.print("error: '{s}' has multiple assets. Use '@' to specify:\n", .{url});
            for (keys) |k| std.debug.print("  {s}\n", .{k});
            return error.AmbiguousMatch;
        }
        return error.NoInstallRecord;
    } else |_| {}
    // 短名称查找
    const short = try findByShortName(state, url);
    return try allocator.dupe(u8, short);
}

/// 程序入口：捕获所有错误并统一打印
pub fn main(init: std.process.Init) void {
    defer if (curl_handle) |h| cURL.curl_easy_cleanup(h);
    mainInner(init) catch {
        std.process.cleanExit(init.io);
    };
}

/// install 命令核心逻辑
fn doInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    state_path: []const u8,
    args: Args,
    candidate: AssetCandidate,
) !void {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // 确定安装目录
    const install_dir = if (args.output) |out|
        if (std.fs.path.isAbsolute(out))
            try allocator.dupe(u8, out)
        else
            try std.fs.path.join(allocator, &.{ cwd_path, out })
    else if (args.extract) blk: {
        var dir_name = candidate.name;
        inline for (.{ ".tar.gz", ".tar.xz", ".tgz", ".zip", ".xz" }) |ext| {
            if (std.ascii.endsWithIgnoreCase(dir_name, ext)) {
                dir_name = dir_name[0 .. dir_name.len - ext.len];
                break;
            }
        }
        break :blk try std.fs.path.join(allocator, &.{ cwd_path, dir_name });
    } else
        try getInstallDir(allocator, home_dir);
    defer allocator.free(install_dir);

    const full = args.extract; // -x 模式保留全部文件
    const custom = args.output != null; // 自定义路径模式
    // lean 模式需要追踪增量文件
    const before = if (!full and !custom) try listEntries(allocator, io, install_dir) else null;
    defer if (before) |b| freeEntries(allocator, b);

    const slug = try parseRepoSlug(args.url.?);
    const base_key = try slugKey(slug, allocator);
    defer allocator.free(base_key);

    var old = try loadState(allocator, io, state_path);
    defer old.deinit();

    const existing = try findRepoRecords(&old, base_key);
    defer allocator.free(existing);

    // 确定状态键：同仓库多不同资产时使用 @asset 后缀
    const repo_key = if (existing.len == 0)
        try allocator.dupe(u8, base_key)
    else if (existing.len == 1 and std.mem.findScalar(u8, existing[0], '@') == null) blk: {
        const rec = findRecord(&old, existing[0]).?;
        if (std.mem.eql(u8, rec.selected_asset_name, candidate.name)) {
            // 相同资产 + 相同版本 + 相同路径 → 跳过
            if (std.mem.eql(u8, rec.installed_version, candidate.release_tag) and
                std.mem.eql(u8, rec.install_dir, install_dir))
            {
                std.debug.print("{s} {s} is already installed\n", .{ base_key, candidate.release_tag });
                return;
            }
            // 路径变更 → 清理旧安装再重装
            removeRecordFiles(allocator, io, &rec);
            break :blk try allocator.dupe(u8, existing[0]);
        }
        // 不同资产 → 迁移旧键为 @asset 格式
        try migrateRecordKey(allocator, &old, existing[0], base_key);
        break :blk try assetKey(slug, candidate.name, allocator);
    } else
        try assetKey(slug, candidate.name, allocator);
    defer allocator.free(repo_key);


    try installAsset(allocator, io, candidate, install_dir, !full);

    // 计算 installed_files
    const is_archive = isCompressedFormat(basenameFromUrl(candidate.browser_download_url));
    const installed_files = if (full)
        &.{} // -x 模式：不追踪具体文件
    else if (custom and !is_archive) blk: {
        const name = basenameFromUrl(candidate.browser_download_url);
        const files = try allocator.alloc([]const u8, 1);
        files[0] = try allocator.dupe(u8, name);
        break :blk files;
    } else if (!custom) blk: {
        // 默认安装目录：对比前后差异获取新增文件
        const after = try listEntries(allocator, io, install_dir);
        defer freeEntries(allocator, after);
        const new_entries = try diffEntries(allocator, before.?, after);
        break :blk if (findRecord(&old, repo_key)) |r|
            try mergeEntries(allocator, r.installed_files, new_entries)
        else
            new_entries;
    } else &.{};

    try writeInstallRecord(allocator, io, &old, state_path, repo_key, args, candidate, install_dir, if (full) "full" else "lean", installed_files);
    std.debug.print("Installed {s} to {s}\n", .{ candidate.release_tag, install_dir });
}

/// 主逻辑：路由到各子命令
fn mainInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    const home_dir = environ_map.get("HOME") orelse {
        std.debug.print("error: HOME environment variable not set\n", .{});
        return error.HomeDirNotFound;
    };

    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iter.deinit();

    const args = parseArgs(&iter);
    validateArgs(args) catch |err| {
        if (err == error.HelpRequested) return;
        return err;
    };

    const state_path = try getStatePath(allocator, home_dir);
    defer allocator.free(state_path);

    // ---- LIST ----
    if (args.cmd == .list) {
        var state = try loadState(allocator, io, state_path);
        defer state.deinit();

        if (state.records.count() == 0) {
            std.debug.print("No packages installed.\n", .{});
            return;
        }
        // 计算最长的仓库名宽度用于对齐
        var max_width: usize = "REPO".len;
        {
            var it = state.records.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.*.len > max_width) max_width = entry.key_ptr.*.len;
            }
        }
        // 打印表头
        var hdr_buf: [64]u8 = undefined;
        const repo_hdr = try std.fmt.bufPrint(&hdr_buf, "{s}", .{"REPO"});
        var pad_buf: [64]u8 = undefined;
        @memset(pad_buf[0..@min(pad_buf.len, max_width)], ' ');
        const pad = pad_buf[0..max_width];
        std.debug.print("\n  {s}{s}  {s:>7}  {s}\n", .{ repo_hdr, pad[repo_hdr.len..], "VERSION", "INSTALLED" });
        std.debug.print("  {s}{s}  {s:>7}  {s}\n", .{ "----", pad["----".len..], "-------", "---------" });
        var it = state.records.iterator();
        while (it.next()) |entry| {
            const rec = entry.value_ptr;
            std.debug.print("  {s}{s}  {s:>7}  {s}\n", .{ entry.key_ptr.*, pad[entry.key_ptr.*.len..], rec.installed_version, rec.installed_at });
        }
        std.debug.print("\n", .{});
        return;
    }

    // ---- REMOVE ----
    if (args.cmd == .remove) {
        var state = try loadState(allocator, io, state_path);
        defer state.deinit();

        const repo_key = resolveRepoKey(allocator, &state, args.url.?) catch |err| {
            if (err == error.NoInstallRecord) {
                std.debug.print("error: '{s}' is not installed\n", .{args.url.?});
                return err;
            }
            return err;
        };
        defer allocator.free(repo_key);

        const record = findRecord(&state, repo_key).?;
        std.debug.print("Removing {s} ({s})...\n", .{ repo_key, record.installed_version });

        removeRecordFiles(allocator, io, &record);

        // 从状态中移除记录
        if (state.records.fetchRemove(repo_key)) |kv| {
            allocator.free(kv.key);
            freeRecordFields(allocator, @constCast(&kv.value));
        }
        try saveState(&state, io, state_path);
        std.debug.print("Removed {s}\n", .{repo_key});
        return;
    }

    // ---- UPDATE ALL (按已安装的所有项目) ----
    if (args.cmd == .update and args.url == null) {
        var st = try loadState(allocator, io, state_path);
        defer st.deinit();
        if (st.records.count() == 0) {
            std.debug.print("No packages installed.\n", .{});
            return;
        }
        var keys: std.ArrayList([]const u8) = .empty;
        {
            var it = st.records.iterator();
            while (it.next()) |entry| {
                try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        defer {
            for (keys.items) |k| allocator.free(k);
            keys.deinit(allocator);
        }
        for (keys.items) |key| {
            std.debug.print("\n--- {s} ---\n", .{key});
            updateOne(allocator, io, &st, state_path, key, args) catch |err| {
                std.debug.print("  failed: {}\n", .{err});
            };
        }
        try saveState(&st, io, state_path);
        std.debug.print("\nDone.\n", .{});
        return;
    }

    // ---- UPDATE (单个仓库) ----
    if (args.cmd == .update) {
        var state = try loadState(allocator, io, state_path);
        defer state.deinit();

        const single_key = resolveRepoKey(allocator, &state, args.url.?) catch |err| switch (err) {
            error.NoInstallRecord => {
                std.debug.print("error: '{s}' is not installed. Run `snag install {s}` first.\n", .{ args.url.?, args.url.? });
                return err;
            },
            error.AmbiguousMatch => null, // null 触发下面的多资产更新
            else => |e| return e,
        };

        if (single_key) |key| {
            const repo_key = try allocator.dupe(u8, key);
            defer allocator.free(repo_key);
            try updateOne(allocator, io, &state, state_path, repo_key, args);
        } else {
            // 多资产：更新该仓库所有资产
            const slug = try parseRepoSlug(args.url.?);
            const repo_slug_str = try slugKey(slug, allocator);
            defer allocator.free(repo_slug_str);
            const keys = try findRepoRecords(&state, repo_slug_str);
            defer allocator.free(keys);
            for (keys) |k| {
                std.debug.print("\n--- {s} ---\n", .{k});
                updateOne(allocator, io, &state, state_path, k, args) catch |err| {
                    std.debug.print("  failed: {}\n", .{err});
                };
            }
            try saveState(&state, io, state_path);
        }
        return;
    }

    // ---- INSTALL / DOWNLOAD（共性：获取 Release + 选择资产） ----
    const candidate = (try fetchAndSelect(allocator, io, args, args.cmd != .download)) orelse {
        std.debug.print("No asset selected.\n", .{});
        return;
    };

    // ---- DOWNLOAD ----
    if (args.cmd == .download) {
        const basename = basenameFromUrl(candidate.browser_download_url);
        const output_dir = if (args.output) |out| trimTrailingSlashes(out) else ".";
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, basename });
        defer allocator.free(output_path);

        if (args.extract) {
            std.debug.print("Downloading: {s}\n", .{candidate.browser_download_url});
            try curlDownload(allocator, io, candidate.browser_download_url, output_path);
            std.debug.print("Extracting...\n", .{});
            if (args.output) |out| {
                try extract(allocator, io, output_path, out);
            } else {
                // 创建以归档名命名的子目录（去除扩展名）
                var ext_dir = basename;
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tar.gz")) ext_dir = ext_dir[0 .. ext_dir.len - 7];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tar.xz")) ext_dir = ext_dir[0 .. ext_dir.len - 7];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tgz")) ext_dir = ext_dir[0 .. ext_dir.len - 4];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".zip")) ext_dir = ext_dir[0 .. ext_dir.len - 4];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".xz")) ext_dir = ext_dir[0 .. ext_dir.len - 3];
                const ext_path = try std.fs.path.join(allocator, &.{ output_dir, ext_dir });
                defer allocator.free(ext_path);
                try extract(allocator, io, output_path, ext_path);
            }
        } else {
            std.debug.print("Downloading: {s}\n", .{candidate.browser_download_url});
            try curlDownload(allocator, io, candidate.browser_download_url, output_path);
        }
        std.debug.print("Done: {s}\n", .{output_path});
        return;
    }

    // ---- INSTALL ----
    try doInstall(allocator, io, home_dir, state_path, args, candidate);
}

// ============================================================================
// 安装文件追踪
// ============================================================================

/// 列出目录中的所有文件和子目录名
fn listEntries(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    } else |_| {}

    return names.toOwnedSlice(allocator);
}

/// 释放条目列表内存
fn freeEntries(allocator: std.mem.Allocator, entries: []const []const u8) void {
    for (entries) |e| allocator.free(e);
    allocator.free(entries);
}

/// 计算 after 中相对于 before 的新增条目
fn diffEntries(allocator: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var new_entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (new_entries.items) |e| allocator.free(e);
        new_entries.deinit(allocator);
    }
    for (after) |name| {
        var found = false;
        for (before) |bname| {
            if (std.mem.eql(u8, name, bname)) { found = true; break; }
        }
        if (!found) try new_entries.append(allocator, try allocator.dupe(u8, name));
    }
    return new_entries.toOwnedSlice(allocator);
}

/// 合并旧条目和新条目（去重）
fn mergeEntries(allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8) ![]const []const u8 {
    const total = old.len + new.len;
    const merged = try allocator.alloc([]const u8, total);
    for (old, 0..) |e, i| merged[i] = try allocator.dupe(u8, e);
    for (new, 0..) |e, i| merged[old.len + i] = e;
    allocator.free(new);
    return merged;
}

/// 写入安装记录到状态文件
fn writeInstallRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    existing_state: ?*StateFile,
    state_path: []const u8,
    repo_key: []const u8,
    args: Args,
    candidate: AssetCandidate,
    install_dir: []const u8,
    install_type: []const u8,
    installed_files: []const []const u8,
) !void {
    const now_str = try nowUtcString(allocator, io);
    defer allocator.free(now_str);

    const record = InstallRecord{
        .repo_url = try allocator.dupe(u8, args.url.?),
        // repo_slug 去除 @asset 后缀，只存储 owner/name
        .repo_slug = try allocator.dupe(u8, if (std.mem.findScalar(u8, repo_key, '@')) |at| repo_key[0..at] else repo_key),
        .install_dir = try allocator.dupe(u8, install_dir),
        .installed_version = try allocator.dupe(u8, candidate.release_tag),
        .selected_asset_name = try allocator.dupe(u8, candidate.name),
        .selected_download_url = try allocator.dupe(u8, candidate.browser_download_url),
        .install_mode = try allocator.dupe(u8, if (isCompressedFormat(candidate.name)) "archive_extract" else "raw_file"),
        .install_type = try allocator.dupe(u8, install_type),
        .installed_files = blk: {
            const files = try allocator.alloc([]const u8, installed_files.len);
            for (installed_files, 0..) |f, i| files[i] = try allocator.dupe(u8, f);
            break :blk files;
        },
        .selected_match_keyword = if (args.match_keyword) |kw| try allocator.dupe(u8, kw) else null,
        .selected_os_arch = if (args.os_arch) |osa| try allocator.dupe(u8, osa) else null,
        .installed_at = try allocator.dupe(u8, now_str),
    };

    if (existing_state) |state| {
        try upsertRecord(state, repo_key, record);
        try saveState(state, io, state_path);
    } else {
        var state = try loadState(allocator, io, state_path);
        defer state.deinit();
        try upsertRecord(&state, repo_key, record);
        try saveState(&state, io, state_path);
    }
}
