const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// TYPES
// ============================================================================

const SubCommand = enum { install, download, update, list, remove };

const AssetCandidate = struct {
    name: []const u8,
    browser_download_url: []const u8,
    release_tag: []const u8,
    score: u8,
    matches_platform: bool,
    matches_keyword: bool,
    matches_os_filter: bool,
};

const InstallRecord = struct {
    repo_url: []const u8,
    repo_slug: []const u8,
    install_dir: []const u8,
    installed_version: []const u8,
    selected_asset_name: []const u8,
    selected_download_url: []const u8,
    install_mode: []const u8, // "archive_extract" or "raw_file"
    install_type: []const u8, // "bin" or "custom"
    selected_match_keyword: ?[]const u8,
    selected_os_arch: ?[]const u8,
    installed_at: []const u8,
};

const StateFile = struct {
    records: std.StringHashMap(InstallRecord),
    allocator: std.mem.Allocator,

    fn deinit(self: *StateFile) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.repo_url);
            self.allocator.free(entry.value_ptr.repo_slug);
            self.allocator.free(entry.value_ptr.install_dir);
            self.allocator.free(entry.value_ptr.installed_version);
            self.allocator.free(entry.value_ptr.selected_asset_name);
            self.allocator.free(entry.value_ptr.selected_download_url);
            self.allocator.free(entry.value_ptr.install_mode);
            self.allocator.free(entry.value_ptr.install_type);
            if (entry.value_ptr.selected_match_keyword) |kw| self.allocator.free(kw);
            if (entry.value_ptr.selected_os_arch) |os| self.allocator.free(os);
            self.allocator.free(entry.value_ptr.installed_at);
        }
        self.records.deinit();
    }
};

const Args = struct {
    cmd: SubCommand = .install,
    url: ?[]const u8 = null,
    version: ?[]const u8 = null,
    match_keyword: ?[]const u8 = null,
    os_arch: ?[]const u8 = null,
    output: ?[]const u8 = null,
    extract: bool = false,
    interactive: bool = false,
    help: bool = false,
};

const RepoSlug = struct {
    owner: []const u8,
    name: []const u8,
};

const Release = struct {
    tag_name: []const u8,
    assets: []const ReleaseAsset,
};

const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const PlatformHints = struct {
    label: []const u8,
    os: []const []const u8,
    arch: []const []const u8,
    other_os: []const []const u8,
    other_arch: []const []const u8,
    generic: []const []const u8 = &empty_aliases,
};

const empty_aliases = [_][]const u8{};

// ============================================================================
// PLATFORM DETECTION
// ============================================================================

const os_macos = [_][]const u8{ "darwin", "macos", "osx" };
const os_linux = [_][]const u8{ "linux", "gnu/linux" };
const os_windows = [_][]const u8{ "windows", "win32", "win64", "mingw" };

const arch_arm64 = [_][]const u8{ "arm64", "aarch64" };
const arch_x64 = [_][]const u8{ "x86_64", "amd64", "x64" };
const arch_x86 = [_][]const u8{ "x86", "386", "i386", "i686" };

const other_os_for_macos = [_][]const u8{ "linux", "windows", "win32", "win64", "mingw", "android" };
const other_os_for_linux = [_][]const u8{ "darwin", "macos", "osx", "windows", "win32", "win64", "mingw", "android" };
const other_os_for_windows = [_][]const u8{ "darwin", "macos", "osx", "linux", "android" };

const other_arch_for_arm64 = [_][]const u8{
    "x86_64", "amd64", "x64", "x86", "386", "i386", "i686", "armv7", "armv6", "armhf", "arm32",
};
const other_arch_for_x64 = [_][]const u8{
    "arm64", "aarch64", "x86", "386", "i386", "i686", "armv7", "armv6", "armhf", "arm32",
};
const other_arch_for_x86 = [_][]const u8{
    "arm64", "aarch64", "x86_64", "amd64", "x64", "armv7", "armv6", "armhf", "arm32",
};

const macos_generic = [_][]const u8{ "universal", "universal2" };

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
// UTILITY FUNCTIONS
// ============================================================================

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

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

fn fmtSize(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

fn nowMonotonicMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

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
// PATH HELPERS
// ============================================================================

fn getSnagBaseDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ home_dir, ".local", "snag" });
}

fn getStatePath(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    const base = try getSnagBaseDir(allocator, home_dir);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "state.json" });
}

fn getInstallDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    const base = try getSnagBaseDir(allocator, home_dir);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "bin" });
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

// ============================================================================
// CLI / ARGS
// ============================================================================

fn usage() void {
    std.debug.print(
        \\snag — GitHub Release Asset Manager
        \\
        \\Usage:
        \\  snag install  <repo>               Install to ~/.local/snag/bin/
        \\  snag install  <repo> -x <path>     Extract to path, track in state
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

fn looksLikeRepo(arg: []const u8) bool {
    return std.mem.indexOfScalar(u8, arg, '/') != null or
        std.ascii.indexOfIgnoreCase(arg, "github.com") != null;
}

fn isFlag(s: []const u8) bool {
    return s.len > 0 and s[0] == '-';
}

fn parseArgs(iter: *std.process.Args.Iterator) Args {
    var args = Args{};
    _ = iter.skip();
    var want_path: bool = false;

    while (iter.next()) |arg| {
        if (want_path and !isFlag(arg)) {
            args.output = arg;
            want_path = false;
            continue;
        }
        want_path = false;

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
            want_path = true;
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
            args.url = arg;
        } else if (args.cmd == .update or args.cmd == .remove) {
            if (args.url == null) args.url = arg;
        } else if (args.url != null and args.output == null and !isFlag(arg)) {
            args.output = arg;
        }
    }
    return args;
}

fn validateArgs(args: Args) !void {
    if (args.help) {
        usage();
        return error.HelpRequested;
    }
    if (args.cmd == .list) return;
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
    if (args.cmd == .install and args.extract and args.output == null) {
        std.debug.print("error: install -x requires a path (e.g. snag install <repo> -x ./out)\n", .{});
        return error.InvalidArgs;
    }
}

// ============================================================================
// REPO / RELEASE
// ============================================================================

fn trimTrailingSlashes(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] == '/') {
        end -= 1;
    }
    return text[0..end];
}

fn stripRepoPath(text: []const u8) []const u8 {
    var t = text;
    // strip common GitHub URL suffixes
    const suffixes = &[_][]const u8{ "/releases", "/releases/", "/tags", "/tree", ".git" };
    for (suffixes) |suf| {
        if (std.ascii.endsWithIgnoreCase(t, suf)) {
            t = t[0 .. t.len - suf.len];
            break;
        }
    }
    return t;
}

fn parseRepoSlug(repo: []const u8) !RepoSlug {
    var clean = trimTrailingSlashes(repo);
    clean = stripRepoPath(clean);
    clean = trimTrailingSlashes(clean);

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

    var parts = std.mem.splitScalar(u8, clean, '/');
    const owner = parts.next() orelse return error.InvalidRepo;
    const name = parts.next() orelse return error.InvalidRepo;
    if (owner.len == 0 or name.len == 0) return error.InvalidRepo;

    return .{ .owner = owner, .name = name };
}

fn slugKey(slug: RepoSlug, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ slug.owner, slug.name });
}

fn repoApiUrl(allocator: std.mem.Allocator, repo: []const u8, version: ?[]const u8) ![]const u8 {
    const slug = try parseRepoSlug(repo);
    return if (version) |tag|
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/{s}", .{ slug.owner, slug.name, tag })
    else
        std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ slug.owner, slug.name });
}

fn hasProxy(environ_map: *const std.process.Environ.Map) bool {
    const vars = &[_][]const u8{ "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" };
    for (vars) |name| {
        if (environ_map.get(name)) |value| {
            if (value.len > 0) return true;
        }
    }
    return false;
}

fn configureHttpClient(client: *std.http.Client) void {
    client.read_buffer_size = 64 * 1024;
    client.write_buffer_size = 16 * 1024;
    if (!std.http.Client.disable_tls) {
        client.tls_buffer_size = 64 * 1024;
    }
}

fn fetchJson(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, url: []const u8) ![]u8 {
    const use_proxy = hasProxy(environ_map);

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    configureHttpClient(&client);
    if (use_proxy) try client.initDefaultProxies(allocator, environ_map);

    return fetchJsonWithClient(&client, allocator, url) catch |err| {
        if (use_proxy) {
            var client2 = std.http.Client{ .allocator = allocator, .io = io };
            defer client2.deinit();
            configureHttpClient(&client2);
            return fetchJsonWithClient(&client2, allocator, url);
        }
        return err;
    };
}

fn fetchJsonWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) {
        std.debug.print("HTTP {d} for {s}\n", .{ @intFromEnum(result.status), url });
        return error.HttpError;
    }
    return aw.toOwnedSlice();
}

const ParsedRelease = std.json.Parsed(Release);

fn parseRelease(allocator: std.mem.Allocator, json: []const u8) !ParsedRelease {
    return try std.json.parseFromSlice(Release, allocator, json, .{ .ignore_unknown_fields = true });
}

// ============================================================================
// ASSET SELECTOR — scoring, filtering, uniqueness, interaction
// ============================================================================

fn scoreAssetForPlatform(name: []const u8, hints: PlatformHints) ?u8 {
    if (isMetadataFile(name)) return null;

    const os_hit = containsAnyIgnoreCase(name, hints.os);
    const arch_hit = containsAnyIgnoreCase(name, hints.arch);
    const generic_hit = containsAnyIgnoreCase(name, hints.generic);

    if (!os_hit and containsAnyIgnoreCase(name, hints.other_os)) return null;
    if (!arch_hit and containsAnyIgnoreCase(name, hints.other_arch) and !generic_hit) return null;

    var score: u8 = 1;
    if (os_hit) score += 4;
    if (arch_hit) score += 4;
    if (generic_hit) score += 2;
    return score;
}

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
        if (isMetadataFile(asset.name)) continue;

        // keyword filter: if -m is set, asset name must contain it (or skip)
        if (match_keyword) |kw| {
            if (!containsIgnoreCase(asset.name, kw)) continue;
        }

        // os filter: if -os is set, asset name must contain it (loose match)
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
                continue; // wrong platform — filter out
            }
        } else {
            // no platform filter, but still score by auto-detected platform for ranking
            const auto_hints = currentPlatformHints();
            if (scoreAssetForPlatform(asset.name, auto_hints)) |ps| {
                score = ps;
                matches_platform = true;
            }
        }

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
    // sort descending by score
    std.mem.sort(AssetCandidate, candidates, {}, struct {
        fn lt(_: void, a: AssetCandidate, b: AssetCandidate) bool {
            return a.score > b.score;
        }
    }.lt);
    return candidates;
}

fn isObviouslyUnique(candidates: []const AssetCandidate, args: Args) bool {
    if (candidates.len == 0) return false;
    if (candidates.len == 1) return true;
    if (candidates[0].score <= candidates[1].score) return false;
    if (args.match_keyword != null and !candidates[0].matches_keyword) return false;
    if (args.os_arch != null and !candidates[0].matches_os_filter) return false;
    return true;
}

fn collectTags(c: AssetCandidate, buf: *[16]u8) []const u8 {
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

const Key = union(enum) {
    char: u8,
    up,
    down,
    enter,
    esc,
    tab,
    backspace,
};

fn readKey() !Key {
    var buf: [3]u8 = undefined;
    const n = try std.posix.read(0, &buf);
    if (n == 0) return error.Eof;
    if (buf[0] == '\x1b') {
        if (buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                else => .esc,
            };
        }
        return .esc;
    }
    if (buf[0] == '\r' or buf[0] == '\n') return .enter;
    if (buf[0] == '\t') return .tab;
    if (buf[0] == 127 or buf[0] == 8) return .backspace;
    return .{ .char = buf[0] };
}

const RawTerm = if (builtin.os.tag == .windows)
    struct {
        fn enter() !@This() { return .{}; }
        fn exit(_: *@This()) void {}
    }
else
    struct {
        orig: std.posix.termios,

        fn enter() !@This() {
            const orig = try std.posix.tcgetattr(0);
            var raw = orig;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.cc[6] = 1; // VMIN
            raw.cc[5] = 0; // VTIME
            try std.posix.tcsetattr(0, .NOW, raw);
            return .{ .orig = orig };
        }

        fn exit(self: *@This()) void {
            std.posix.tcsetattr(0, .NOW, self.orig) catch {};
        }
    };

fn drawList(candidates: []const AssetCandidate, cursor: usize, filter: []const u8, prev_lines: *usize) void {
    if (prev_lines.* > 0) {
        std.debug.print("\x1b[{}A\r", .{prev_lines.*});
    }
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
        var tag_buf: [16]u8 = undefined;
        const tags = collectTags(candidates[cursor], &tag_buf);
        std.debug.print("\n  v{s} (score: {d}) {s}\n", .{ candidates[cursor].release_tag, candidates[cursor].score, tags });
        lines += 2;
    }
    std.debug.print("  > {s}\x1b[K", .{filter});
    // prev_lines = all lines printed (including prompt, since cursor is ON the prompt line)
    prev_lines.* = lines;
}

fn applyFilter(
    allocator: std.mem.Allocator,
    all_candidates: []const AssetCandidate,
    filter: []const u8,
    filtered: *[]AssetCandidate,
    filtered_len: *usize,
    cursor: *usize,
) !void {
    if (filter.len == 0) {
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

fn interactiveSelect(
    allocator: std.mem.Allocator,
    all_candidates: []const AssetCandidate,
) !?usize {
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

    var term = try RawTerm.enter();
    defer term.exit();

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
            .up => { if (cursor > 0) cursor -= 1; },
            .down => { if (cursor + 1 < filtered_len) cursor += 1; },
            .enter => {
                if (filtered_len == 0) continue;
                const sel = filtered[cursor];
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
// STATE STORE
// ============================================================================

fn loadState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8) !StateFile {
    const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, @enumFromInt(1048576)) catch |err| switch (err) {
        error.FileNotFound => return StateFile{
            .records = std.StringHashMap(InstallRecord).init(allocator),
            .allocator = allocator,
        },
        else => |e| return e,
    };
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
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
        .install_type = try allocator.dupe(u8, getStringField(obj, "install_type") orelse "bin"),
        .selected_match_keyword = if (getStringField(obj, "selected_match_keyword")) |kw| try allocator.dupe(u8, kw) else null,
        .selected_os_arch = if (getStringField(obj, "selected_os_arch")) |osa| try allocator.dupe(u8, osa) else null,
        .installed_at = try allocator.dupe(u8, getStringField(obj, "installed_at") orelse return error.InvalidStateFormat),
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn freeRecordFields(allocator: std.mem.Allocator, rec: *InstallRecord) void {
    allocator.free(rec.repo_url);
    allocator.free(rec.repo_slug);
    allocator.free(rec.install_dir);
    allocator.free(rec.installed_version);
    allocator.free(rec.selected_asset_name);
    allocator.free(rec.selected_download_url);
    allocator.free(rec.install_mode);
    allocator.free(rec.install_type);
    if (rec.selected_match_keyword) |kw| allocator.free(kw);
    if (rec.selected_os_arch) |os| allocator.free(os);
    allocator.free(rec.installed_at);
}

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
            \\    "install_type": "{s}"
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

fn upsertRecord(state: *StateFile, key: []const u8, record: InstallRecord) !void {
    // free existing record if present
    if (state.records.getEntry(key)) |existing| {
        freeRecordFields(state.allocator, existing.value_ptr);
        existing.value_ptr.* = record;
    } else {
        const key_dup = try state.allocator.dupe(u8, key);
        try state.records.put(key_dup, record);
    }
}

fn findRecord(state: *const StateFile, key: []const u8) ?InstallRecord {
    return state.records.get(key);
}

fn findByShortName(state: *const StateFile, short: []const u8) ![]const u8 {
    var match: ?[]const u8 = null;
    var it = state.records.iterator();
    while (it.next()) |entry| {
        const slug = entry.value_ptr.repo_slug;
        if (std.mem.endsWith(u8, slug, short)) {
            // ensure it's the full name part after the last /
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
// UPDATE-SPECIFIC MATCHING
// ============================================================================

const ScoredIdx = struct { idx: usize, score: u8 };

fn tryUpdateMatch(
    candidates: []const AssetCandidate,
    record: InstallRecord,
) ?usize {
    if (candidates.len == 0) return null;

    // 1. Try exact asset name match
    for (candidates, 0..) |c, i| {
        if (std.ascii.eqlIgnoreCase(c.name, record.selected_asset_name)) {
            return i;
        }
    }

    // 2. Try keyword + os from stored record
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
// DOWNLOAD
// ============================================================================

const DownloadProgress = struct {
    label: []const u8,
    total: ?u64,
    downloaded: u64 = 0,
    next_report_at: u64 = 0,
    started_at_ms: i64,
    last_rendered_at_ms: i64,

    fn init(io: std.Io, path: []const u8, total: ?u64) DownloadProgress {
        const now_ms = nowMonotonicMs(io);
        return .{
            .label = std.fs.path.basename(path),
            .total = total,
            .started_at_ms = now_ms,
            .last_rendered_at_ms = now_ms,
        };
    }

    fn advance(self: *DownloadProgress, io: std.Io, amount: usize) void {
        self.downloaded += amount;
        const now_ms = nowMonotonicMs(io);
        if (self.downloaded < self.next_report_at and now_ms - self.last_rendered_at_ms < 200) return;
        self.next_report_at = self.downloaded + 512 * 1024;
        self.render(now_ms, false);
    }

    fn finish(self: *DownloadProgress, io: std.Io) void {
        self.render(nowMonotonicMs(io), true);
    }

    fn render(self: *DownloadProgress, now_ms: i64, done: bool) void {
        self.last_rendered_at_ms = now_ms;
        const elapsed_ms = @max(now_ms - self.started_at_ms, 1);
        const speed_mbps = (@as(f64, @floatFromInt(self.downloaded)) / 1024.0 / 1024.0) /
            (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);

        if (self.total) |total| {
            const percent = if (total == 0)
                100.0
            else
                (@as(f64, @floatFromInt(self.downloaded)) * 100.0) / @as(f64, @floatFromInt(total));
            std.debug.print(
                "\rDownloading {s}: {d:.2}/{d:.2} MB ({d:.1}%) {d:.2} MB/s",
                .{ self.label, fmtSize(self.downloaded), fmtSize(total), percent, speed_mbps },
            );
        } else {
            std.debug.print(
                "\rDownloading {s}: {d:.2} MB {d:.2} MB/s",
                .{ self.label, fmtSize(self.downloaded), speed_mbps },
            );
        }
        if (done) std.debug.print("\n", .{});
    }
};

fn downloadWithClient(client: *std.http.Client, io: std.Io, url: []const u8, path: []const u8) !void {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("HTTP {d} for {s}\n", .{ @intFromEnum(response.head.status), url });
        return error.HttpError;
    }

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_buf: [256 * 1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &file_buf);

    var transfer_buf: [64 * 1024]u8 = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    var read_buf: [256 * 1024]u8 = undefined;
    const progress_total = if (response.head.content_encoding == .identity) response.head.content_length else null;
    var progress = DownloadProgress.init(io, path, progress_total);

    while (true) {
        const n = reader.readSliceShort(&read_buf) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        if (n == 0) break;
        try file_writer.interface.writeAll(read_buf[0..n]);
        progress.advance(io, n);
    }

    try file_writer.interface.flush();
    progress.finish(io);
    std.debug.print("Downloaded: {s} ({d:.2} MB)\n", .{ path, fmtSize(progress.downloaded) });
}

fn download(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    url: []const u8,
    path: []const u8,
) !void {
    const basename = std.fs.path.basename(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.snag-tmp", .{basename});
    defer allocator.free(tmp_path);

    const use_proxy = hasProxy(environ_map);
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    configureHttpClient(&client);
    if (use_proxy) try client.initDefaultProxies(allocator, environ_map);

    downloadWithClient(&client, io, url, tmp_path) catch |err| {
        if (err == error.HttpConnectionClosing) {
            // file was fully downloaded, connection close is benign
        } else if (use_proxy) {
            var client2 = std.http.Client{ .allocator = allocator, .io = io };
            defer client2.deinit();
            configureHttpClient(&client2);
            downloadWithClient(&client2, io, url, tmp_path) catch |e2| {
                std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
                return e2;
            };
            return err;
        } else {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return err;
        }
    };

    try ensureParentDir(io, path);
    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}


// ============================================================================
// EXTRACT
// ============================================================================

fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (switch (res.term) {
        .exited => |code| code != 0,
        else => true,
    }) {
        const name = if (argv.len > 0) argv[0] else "command";
        if (res.stderr.len > 0) {
            std.debug.print("{s} failed: {s}\n", .{ name, res.stderr });
        } else {
            std.debug.print("{s} exited unsuccessfully\n", .{name});
        }
        return error.CommandFailed;
    }
}

fn basenameFromUrl(url: []const u8) []const u8 {
    const query_pos = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const fragment_pos = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    const end = @min(query_pos, fragment_pos);
    return std.fs.path.basename(url[0..end]);
}

fn isCompressedFormat(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".tar.gz") or
        std.ascii.endsWithIgnoreCase(name, ".tar.xz") or
        std.ascii.endsWithIgnoreCase(name, ".tgz") or
        std.ascii.endsWithIgnoreCase(name, ".zip") or
        std.ascii.endsWithIgnoreCase(name, ".xz");
}

fn flattenSingleDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var subdir_name: ?[]const u8 = null;
    var file_count: usize = 0;
    var iter = dir.iterate();
    defer if (subdir_name) |n| allocator.free(n);
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (subdir_name != null) return; // multiple dirs, don't flatten
            subdir_name = try allocator.dupe(u8, entry.name);
        } else {
            file_count += 1;
        }
    }
    // only flatten if exactly 1 dir and 0 files
    if (subdir_name == null or file_count > 0) return;

    const sub_path = try std.fs.path.join(allocator, &.{ dir_path, subdir_name.? });
    defer allocator.free(sub_path);

    // move everything from subdir up
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
    // remove now-empty subdir
    try std.Io.Dir.cwd().deleteDir(io, sub_path);
}

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
// INSTALL
// ============================================================================

fn isJunkFile(name: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    const lower = lower_buf[0..@min(name.len, 256)];
    for (name[0..lower.len], 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    const exact = &[_][]const u8{
        "readme", "readme.md", "readme.txt", "readme.markdown",
        "license", "license.md", "license.txt",
        "changelog", "changelog.md", "changelog.txt",
        "contributing", "contributing.md",
        "code_of_conduct", "code_of_conduct.md",
        "security", "security.md",
        "authors", "authors.txt",
        "copyright", "notice",
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

fn installAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    candidate: AssetCandidate,
    install_dir: []const u8,
    clean_junk: bool,
) !void {
    try ensureDir(io, install_dir);

    const basename = basenameFromUrl(candidate.browser_download_url);
    const tmp_path = try std.fs.path.join(allocator, &.{ trimTrailingSlashes(install_dir), basename });
    defer allocator.free(tmp_path);

    std.debug.print("Downloading: {s}\n", .{candidate.browser_download_url});
    try download(allocator, io, environ_map, candidate.browser_download_url, tmp_path);

    const is_archive = isCompressedFormat(basename);

    if (is_archive) {
        std.debug.print("Extracting to: {s}\n", .{install_dir});
        try extract(allocator, io, tmp_path, install_dir);
        if (clean_junk) {
            std.debug.print("Cleaning up junk files...\n", .{});
            try cleanInstallDir(allocator, io, install_dir);
        }
    }

    std.debug.print("Installed: {s}\n", .{install_dir});
}

// ============================================================================
// MAIN
// ============================================================================

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
    // ambiguous — auto-enter interactive
    std.debug.print("Multiple candidates found, entering interactive mode...\n", .{});
    return try interactiveSelect(allocator, candidates);
}

fn fetchAndSelect(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    args: Args,
    auto_platform: bool,
) !?AssetCandidate {
    std.debug.print("Fetching release info...\n", .{});
    const api_url = try repoApiUrl(allocator, args.url.?, args.version);
    defer allocator.free(api_url);

    const json = try fetchJson(allocator, io, environ_map, api_url);
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

fn resolveRepoKey(
    allocator: std.mem.Allocator,
    state: *const StateFile,
    url: []const u8,
) ![]const u8 {
    // First try as owner/repo or full URL
    if (parseRepoSlug(url)) |slug| {
        const key = try slugKey(slug, allocator);
        if (state.records.get(key) != null) return key;
        allocator.free(key);
        return error.NoInstallRecord;
    } else |_| {}
    // Short name lookup returns map-owned pointer; dup for caller
    const short = try findByShortName(state, url);
    return try allocator.dupe(u8, short);
}

pub fn main(init: std.process.Init) !void {
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
        std.debug.print("\n  {s}  {s:>12}  {s}\n", .{ "REPO", "VERSION", "INSTALLED" });
        std.debug.print("  {s}  {s:>12}  {s}\n", .{ "----", "-------", "---------" });
        var it = state.records.iterator();
        while (it.next()) |entry| {
            const rec = entry.value_ptr;
            std.debug.print("  {s}  {s:>12}  {s}\n", .{ entry.key_ptr.*, rec.installed_version, rec.installed_at });
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

        // Recursively delete everything in the install dir
        std.Io.Dir.cwd().deleteTree(io, record.install_dir) catch |err| {
            std.debug.print("  (warning: could not clean {s}: {})\n", .{ record.install_dir, err });
        };

        // Remove from state (fetchRemove returns KV and removes, we must free manually)
        if (state.records.fetchRemove(repo_key)) |kv| {
            allocator.free(kv.key);
            freeRecordFields(allocator, @constCast(&kv.value));
        }
        try saveState(&state, io, state_path);
        std.debug.print("Removed {s}\n", .{repo_key});
        return;
    }

    // ---- UPDATE ----
    if (args.cmd == .update) {
        var state = try loadState(allocator, io, state_path);
        defer state.deinit();

        const repo_key_raw = resolveRepoKey(allocator, &state, args.url.?) catch |err| {
            if (err == error.NoInstallRecord) {
                std.debug.print("error: '{s}' is not installed. Run `snag install {s}` first.\n", .{ args.url.?, args.url.? });
                return err;
            }
            return err;
        };
        const repo_key = try allocator.dupe(u8, repo_key_raw);
        defer allocator.free(repo_key);

        const record = findRecord(&state, repo_key).?;
        std.debug.print("Fetching release info for {s}...\n", .{repo_key});

        // Use the stored repo_url for the API call, fallback to repo_key
        const api_url = repoApiUrl(allocator, record.repo_url, args.version) catch
            try repoApiUrl(allocator, repo_key, args.version);
        defer allocator.free(api_url);

        const json = try fetchJson(allocator, io, environ_map, api_url);
        defer allocator.free(json);

        const parsed = try parseRelease(allocator, json);
        defer parsed.deinit();
        const release = parsed.value;

        const auto_detect = args.os_arch == null and record.selected_os_arch == null;
        const platform = if (auto_detect) currentPlatformHints() else null;
        const candidates = try collectCandidates(
            allocator, release,
            if (args.match_keyword) |_| args.match_keyword else record.selected_match_keyword,
            if (args.os_arch) |_| args.os_arch else record.selected_os_arch,
            platform,
        );
        defer allocator.free(candidates);

        const selected_idx = tryUpdateMatch(candidates, record);
        if (selected_idx) |idx| {
            const c = candidates[idx];
            std.debug.print("Updating {s} to {s}...\n", .{ repo_key, c.release_tag });
            const do_clean = std.mem.eql(u8, record.install_type, "bin");
            try installAsset(allocator, io, environ_map, c, record.install_dir, do_clean);
            try writeInstallRecord(allocator, io, &state, state_path, repo_key, args, c, record.install_dir, record.install_type);
            std.debug.print("Updated {s} to {s}\n", .{ repo_key, c.release_tag });
            return;
        }

        if (args.interactive) {
            std.debug.print("Auto-match failed for update, entering interactive mode...\n", .{});
            const idx = try interactiveSelect(allocator, candidates);
            if (idx) |i| {
                const c = candidates[i];
                const do_clean2 = std.mem.eql(u8, record.install_type, "bin");
                try installAsset(allocator, io, environ_map, c, record.install_dir, do_clean2);
                try writeInstallRecord(allocator, io, &state, state_path, repo_key, args, c, record.install_dir, record.install_type);
                std.debug.print("Updated {s} to {s}\n", .{ repo_key, c.release_tag });
                return;
            }
            std.debug.print("Update cancelled.\n", .{});
            return;
        }

        std.debug.print("error: ambiguous match for update. Use -i for interactive selection.\n", .{});
        return error.AmbiguousMatch;
    }

    // ---- INSTALL / DOWNLOAD (both need to fetch + select) ----
    const candidate = (try fetchAndSelect(allocator, io, environ_map, args, args.cmd != .download)) orelse {
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
            try download(allocator, io, environ_map, candidate.browser_download_url, output_path);
            std.debug.print("Extracting...\n", .{});
            if (args.output) |out| {
                try extract(allocator, io, output_path, out);
            } else {
                // create dir named after archive (strip extension(s))
                var ext_dir = basename;
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tar.gz")) ext_dir = ext_dir[0..ext_dir.len-7];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tar.xz")) ext_dir = ext_dir[0..ext_dir.len-7];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".tgz")) ext_dir = ext_dir[0..ext_dir.len-4];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".zip")) ext_dir = ext_dir[0..ext_dir.len-4];
                if (std.ascii.endsWithIgnoreCase(ext_dir, ".xz")) ext_dir = ext_dir[0..ext_dir.len-3];
                const ext_path = try std.fs.path.join(allocator, &.{ output_dir, ext_dir });
                defer allocator.free(ext_path);
                try extract(allocator, io, output_path, ext_path);
            }
        } else {
            std.debug.print("Downloading: {s}\n", .{candidate.browser_download_url});
            try download(allocator, io, environ_map, candidate.browser_download_url, output_path);
        }
        std.debug.print("Done: {s}\n", .{output_path});
        return;
    }

    // ---- INSTALL ----
    const install_dir = if (args.extract)
        try allocator.dupe(u8, args.output.?) // install -x <path>
    else
        try getInstallDir(allocator, home_dir);
    defer allocator.free(install_dir);

    const is_custom_install = args.extract;
    try installAsset(allocator, io, environ_map, candidate, install_dir, !is_custom_install);

    const slug = try parseRepoSlug(args.url.?);
    const repo_key = try slugKey(slug, allocator);
    defer allocator.free(repo_key);

    try writeInstallRecord(allocator, io, null, state_path, repo_key, args, candidate, install_dir, if (is_custom_install) "custom" else "bin");
    std.debug.print("Installed {s} to {s}\n", .{ candidate.release_tag, install_dir });
}

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
) !void {
    const now_str = try nowUtcString(allocator, io);
    defer allocator.free(now_str);

    const record = InstallRecord{
        .repo_url = try allocator.dupe(u8, args.url.?),
        .repo_slug = try allocator.dupe(u8, repo_key),
        .install_dir = try allocator.dupe(u8, install_dir),
        .installed_version = try allocator.dupe(u8, candidate.release_tag),
        .selected_asset_name = try allocator.dupe(u8, candidate.name),
        .selected_download_url = try allocator.dupe(u8, candidate.browser_download_url),
        .install_mode = try allocator.dupe(u8, if (isCompressedFormat(candidate.name)) "archive_extract" else "raw_file"),
        .install_type = try allocator.dupe(u8, install_type),
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

// ============================================================================
// TESTS
// ============================================================================

test "repoApiUrl accepts shorthand and strips suffixes" {
    const latest = try repoApiUrl(std.testing.allocator, "https://github.com/owner/repo.git/", null);
    defer std.testing.allocator.free(latest);
    try std.testing.expectEqualStrings("https://api.github.com/repos/owner/repo/releases/latest", latest);

    const tagged = try repoApiUrl(std.testing.allocator, "owner/repo", "v1.2.3");
    defer std.testing.allocator.free(tagged);
    try std.testing.expectEqualStrings("https://api.github.com/repos/owner/repo/releases/tags/v1.2.3", tagged);
}

test "isMetadataFile ignores checksums and signatures" {
    try std.testing.expect(isMetadataFile("CHECKSUMS.txt"));
    try std.testing.expect(isMetadataFile("tool.tar.gz.sha256"));
    try std.testing.expect(isMetadataFile("tool.tar.gz.asc"));
    try std.testing.expect(!isMetadataFile("tool-darwin-arm64.tar.gz"));
}

test "collectCandidates scores and filters metadata" {
    const release = Release{
        .tag_name = "v1.0.0",
        .assets = &[_]ReleaseAsset{
            .{ .name = "tool-Linux-x86_64.tar.gz", .browser_download_url = "https://example.invalid/linux" },
            .{ .name = "tool-Darwin-arm64.tar.gz", .browser_download_url = "https://example.invalid/darwin" },
            .{ .name = "checksums.txt", .browser_download_url = "https://example.invalid/checksums" },
        },
    };

    const test_macos_arm64 = PlatformHints{
        .label = "macos/arm64",
        .os = &os_macos,
        .arch = &arch_arm64,
        .other_os = &other_os_for_macos,
        .other_arch = &other_arch_for_arm64,
        .generic = &macos_generic,
    };

    const candidates = try collectCandidates(std.testing.allocator, release, null, null, test_macos_arm64);
    defer std.testing.allocator.free(candidates);

    // Linux filtered out (wrong OS), checksums filtered (metadata) → only Darwin remains
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("tool-Darwin-arm64.tar.gz", candidates[0].name);
    try std.testing.expect(candidates[0].score >= 1);
}

test "collectCandidates without platform hints returns all non-metadata" {
    const release = Release{
        .tag_name = "v1.0.0",
        .assets = &[_]ReleaseAsset{
            .{ .name = "tool-Linux-x86_64.tar.gz", .browser_download_url = "https://example.invalid/linux" },
            .{ .name = "tool-Darwin-arm64.tar.gz", .browser_download_url = "https://example.invalid/darwin" },
            .{ .name = "checksums.txt", .browser_download_url = "https://example.invalid/checksums" },
        },
    };

    const candidates = try collectCandidates(std.testing.allocator, release, null, null, null);
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
}

test "collectCandidates accepts macOS universal assets but rejects wrong arch" {
    const release = Release{
        .tag_name = "v1.0.0",
        .assets = &[_]ReleaseAsset{
            .{ .name = "tool-macos-x86_64.tar.gz", .browser_download_url = "https://example.invalid/x64" },
            .{ .name = "tool-macos-universal2.tar.gz", .browser_download_url = "https://example.invalid/universal" },
        },
    };

    const test_macos_arm64 = PlatformHints{
        .label = "macos/arm64",
        .os = &os_macos,
        .arch = &arch_arm64,
        .other_os = &other_os_for_macos,
        .other_arch = &other_arch_for_arm64,
        .generic = &macos_generic,
    };

    const candidates = try collectCandidates(std.testing.allocator, release, null, null, test_macos_arm64);
    defer std.testing.allocator.free(candidates);

    // x86_64 filtered out (wrong arch, not generic), only universal2 remains
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("tool-macos-universal2.tar.gz", candidates[0].name);
}

test "isObviouslyUnique with single candidate" {
    const candidates = [_]AssetCandidate{
        .{ .name = "tool", .browser_download_url = "url", .release_tag = "v1", .score = 5, .matches_platform = true, .matches_keyword = true, .matches_os_filter = false },
    };
    try std.testing.expect(isObviouslyUnique(&candidates, Args{}));
}

test "isObviouslyUnique with two candidates and clear winner" {
    const candidates = [_]AssetCandidate{
        .{ .name = "a", .browser_download_url = "u", .release_tag = "v1", .score = 15, .matches_platform = true, .matches_keyword = true, .matches_os_filter = true },
        .{ .name = "b", .browser_download_url = "u", .release_tag = "v1", .score = 3, .matches_platform = false, .matches_keyword = false, .matches_os_filter = false },
    };
    try std.testing.expect(isObviouslyUnique(&candidates, .{ .match_keyword = "test", .os_arch = "linux" }));
}

test "isObviouslyUnique with two equal-score candidates is not unique" {
    const candidates = [_]AssetCandidate{
        .{ .name = "a", .browser_download_url = "u", .release_tag = "v1", .score = 9, .matches_platform = true, .matches_keyword = false, .matches_os_filter = false },
        .{ .name = "b", .browser_download_url = "u", .release_tag = "v1", .score = 9, .matches_platform = true, .matches_keyword = false, .matches_os_filter = false },
    };
    try std.testing.expect(!isObviouslyUnique(&candidates, Args{}));
}

test "validateArgs rejects invalid combinations" {
    try std.testing.expectError(error.InvalidArgs, validateArgs(.{ .cmd = .update, .url = "a/b", .extract = true }));
    try std.testing.expectError(error.InvalidArgs, validateArgs(.{ .cmd = .install, .url = "a/b", .extract = true }));
    try std.testing.expectError(error.InvalidArgs, validateArgs(.{ .cmd = .download }));
    try validateArgs(.{ .cmd = .list });
    try validateArgs(.{ .cmd = .install, .url = "a/b" });
    try validateArgs(.{ .cmd = .download, .url = "a/b" });
    try validateArgs(.{ .cmd = .download, .url = "a/b", .extract = true });
    try validateArgs(.{ .cmd = .install, .url = "a/b", .extract = true, .output = "/tmp" });
}

test "slugKey formats correctly" {
    const slug = RepoSlug{ .owner = "blacktop", .name = "ida-mcp-rs" };
    const key = try slugKey(slug, std.testing.allocator);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("blacktop/ida-mcp-rs", key);
}

test "isCompressedFormat detects archive types" {
    try std.testing.expect(isCompressedFormat("tool.tar.gz"));
    try std.testing.expect(isCompressedFormat("tool.tar.xz"));
    try std.testing.expect(isCompressedFormat("tool.tgz"));
    try std.testing.expect(isCompressedFormat("tool.zip"));
    try std.testing.expect(isCompressedFormat("tool.xz"));
    try std.testing.expect(!isCompressedFormat("tool.exe"));
    try std.testing.expect(!isCompressedFormat("tool"));
}
