const std = @import("std");
const builtin = @import("builtin");

const panic = std.debug.panic;

const ArrayList = std.ArrayList;
const Tuple = std.meta.Tuple;

const Allocator = std.mem.Allocator;

const PERF_EVENTS: []const u8 = "cache-references,cache-misses,cycles,instructions,branches,faults,migrations";

const TEST_ASSETS_PATH: []const u8 = "assets/";

const TestAssets = ArrayList(Tuple(&.{ []u8, []u8 }));

// TODO: Make this comptime
fn get_test_assets(allocator: std.mem.Allocator, path: []const u8) !TestAssets {
    var ret = ArrayList(Tuple(&.{ []u8, []u8 })).init(allocator);

    var assets = if (std.fs.path.isAbsolute(path))
        try std.fs.openDirAbsolute(path, .{ .iterate = true })
    else
        try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer assets.close();

    var walker = try assets.walk(allocator);

    while (try walker.next()) |entry| {
        if (std.mem.endsWith(u8, ".sh", entry.basename)) continue;

        const basename = entry.basename[0..entry.basename.len];

        try ret.append(.{
            // This is fine for this use-case
            try allocator.dupe(u8, basename), // name
            try std.mem.concat(allocator, u8, &.{ // path
                path,
                basename,
            }),
        });
    }

    return ret;
}

fn add_assets(b: *std.Build, cmp: *std.Build.Step.Compile, assets: *const TestAssets) void {
    for (assets.items) |asset| {
        const name, const file = asset;

        cmp.root_module.addAnonymousImport(
            name,
            .{
                .root_source_file = if (std.fs.path.isAbsolute(file))
                    .{ .cwd_relative = file }
                else
                    b.path(file),
            },
        );
    }
}

const Test = struct {
    root_source_file: std.Build.LazyPath,

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    mod: ?*std.Build.Module = null,
    mod_name: ?[]const u8 = null,

    use_lld: bool = true,
    use_llvm: bool = true,

    assets: ?*const TestAssets = null,

    name: []const u8,
};

fn add_test(b: *std.Build, step: *std.Build.Step, t: Test) !void {
    const test_case = b.addTest(.{
        .root_source_file = t.root_source_file,
        .target = t.target,
        .optimize = t.optimize,
        .use_llvm = t.use_llvm,
        .use_lld = t.use_lld,
        .name = t.name,
    });

    if (t.mod) |mod|
        test_case.root_module.addImport(t.mod_name.?, mod);

    if (t.assets) |assets|
        add_assets(b, test_case, assets);

    var run_test_case = b.addRunArtifact(test_case);
    run_test_case.has_side_effects = true;

    step.dependOn(&run_test_case.step);
}

const PerfOpt = enum { @"verify-cert", @"verify-sig", cert, sk, pk, sig, all };

const Perf = struct {
    target: std.Build.ResolvedTarget,
    opt: PerfOpt,

    mod: ?*std.Build.Module = null,
    mod_name: ?[]const u8 = null,

    use_llvm: bool,
    use_lld: bool,

    record: bool,

    assets: ?*const TestAssets = null,
};

fn add_perf(b: *std.Build, step: *std.Build.Step, perf: Perf) !void {
    const perf_file = b.fmt("perf/{s}.zig", .{@tagName(perf.opt)});

    const perf_exe = b.addExecutable(.{
        .name = b.fmt("perf: {s}", .{@tagName(perf.opt)}),
        .root_source_file = b.path(perf_file),
        .target = perf.target,
        .use_lld = perf.use_lld,
        .use_llvm = perf.use_llvm,
        .omit_frame_pointer = true,
        .optimize = .ReleaseFast,
    });

    if (perf.mod) |mod|
        perf_exe.root_module.addImport(perf.mod_name.?, mod);

    if (perf.assets) |assets|
        add_assets(b, perf_exe, assets);

    const run_perf = if (perf.record)
        b.addSystemCommand(&.{ "perf", "record", "-e", PERF_EVENTS, "-d", "--" })
    else
        b.addSystemCommand(&.{ "perf", "stat", "-d", "--" });

    const emit_assembly = b.addWriteFiles();
    _ = emit_assembly.addCopyFile(
        perf_exe.getEmittedAsm(),
        b.fmt("{s}.asm", .{@tagName(perf.opt)}),
    );

    run_perf.has_side_effects = true;
    run_perf.addArtifactArg(perf_exe);

    step.dependOn(&run_perf.step);
    step.dependOn(&emit_assembly.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llvm = !(b.option(bool, "nollvm", "Don't use LLVM") orelse false);

    const lld = if (builtin.os.tag == .windows or builtin.os.tag == .macos) false else llvm;

    const mod = b.addModule("zssh", .{
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = b.pathFromRoot("src/zssh.zig"),
            },
        },
        .target = target,
        .optimize = optimize,
    });

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    arena.deinit();

    const assets_path = if (b.build_root.path) |path|
        std.fs.path.join(arena.allocator(), &[_][]const u8{ path, TEST_ASSETS_PATH }) catch @panic("OOM")
    else
        null;

    const assets = get_test_assets(arena.allocator(), assets_path orelse TEST_ASSETS_PATH) catch
        @panic("Fail to get test certs");

    const test_step = b.step("test", "Run unit tests");
    {
        add_test(b, test_step, .{
            .name = "mem",
            .root_source_file = b.path("src/mem.zig"),
            .target = target,
            .optimize = optimize,
            .mod = mod,
            .mod_name = "zssh",
            .use_lld = lld,
            .use_llvm = llvm,
        }) catch @panic("OOM");

        add_test(b, test_step, .{
            .name = "cert",
            .root_source_file = b.path("test/cert.zig"),
            .target = target,
            .optimize = optimize,
            .mod = mod,
            .mod_name = "zssh",
            .use_lld = lld,
            .use_llvm = llvm,
            .assets = &assets,
        }) catch @panic("OOM");

        add_test(b, test_step, .{
            .name = "sig",
            .root_source_file = b.path("test/sig.zig"),
            .target = target,
            .optimize = optimize,
            .mod = mod,
            .mod_name = "zssh",
            .use_lld = lld,
            .use_llvm = llvm,
            .assets = &assets,
        }) catch @panic("OOM");

        add_test(b, test_step, .{
            .name = "pk",
            .root_source_file = b.path("test/pk.zig"),
            .target = target,
            .optimize = optimize,
            .mod = mod,
            .mod_name = "zssh",
            .use_lld = lld,
            .use_llvm = llvm,
            .assets = &assets,
        }) catch @panic("OOM");

        add_test(b, test_step, .{
            .name = "sk",
            .root_source_file = b.path("test/sk.zig"),
            .target = target,
            .optimize = optimize,
            .mod = mod,
            .mod_name = "zssh",
            .use_lld = lld,
            .use_llvm = llvm,
            .assets = &assets,
        }) catch @panic("OOM");

        add_test(b, test_step, .{
            .name = "enc",
            .root_source_file = b.path("src/enc.zig"),
            .target = target,
            .optimize = optimize,
            .use_lld = lld,
            .use_llvm = llvm,
            .assets = &assets,
        }) catch @panic("OOM");
    }

    const docs_step = b.step("docs", "Build documentation");
    {
        const docs_obj = b.addObject(.{
            .name = "zssh",
            .root_source_file = b.path("src/zssh.zig"),
            .target = target,
            .optimize = optimize,
        });

        const install_docs = b.addInstallDirectory(.{
            .install_dir = .prefix,
            .install_subdir = "docs",
            .source_dir = docs_obj.getEmittedDocs(),
        });

        docs_step.dependOn(&docs_obj.step);
        docs_step.dependOn(&install_docs.step);
    }

    const perf_step = b.step("perf", "Perf record");
    {
        const opt =
            b.option(PerfOpt, "perf", "Perf to run (default: key)") orelse .all;

        const record =
            b.option(bool, "record", "Perf record?") orelse false;

        if (opt == .all) {
            if (record) @panic("-Drecord cannot be used with -Dperf=all");

            @setEvalBranchQuota(2000);
            inline for (comptime std.meta.fields(PerfOpt)) |field| {
                comptime if (std.mem.eql(u8, "all", field.name)) continue;

                add_perf(b, perf_step, .{
                    .assets = &assets,
                    .mod = mod,
                    .mod_name = "zssh",
                    .opt = comptime std.meta.stringToEnum(PerfOpt, field.name).?,
                    .record = false,
                    .target = target,
                    .use_lld = lld,
                    .use_llvm = llvm,
                }) catch @panic("OOM");
            }
        } else {
            add_perf(b, perf_step, .{
                .assets = &assets,
                .mod = mod,
                .mod_name = "zssh",
                .opt = opt,
                .record = record,
                .target = target,
                .use_lld = lld,
                .use_llvm = llvm,
            }) catch @panic("OOM");
        }
    }

    const dummy = b.addTest(.{
        .name = "zssh",
        .root_source_file = b.path("src/zssh.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(dummy);

    const dummy_check = b.addTest(.{
        .name = "zssh",
        .root_source_file = b.path("src/zssh.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check = b.step("check", "Check if it compiles");
    check.dependOn(&dummy_check.step);
}
