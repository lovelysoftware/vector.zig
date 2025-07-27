const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vector_mod = b.createModule(.{
        .root_source_file = b.path("src/vector.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vector_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "vector",
        .root_module = vector_mod,
    });
    b.installArtifact(vector_lib);

    const download_sift = b.addSystemCommand(&.{"bash"});
    download_sift.addArgs(&.{
        "sift.sh",
        "siftsmall",
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filters",
        "Run specific unit tests",
    ) orelse &[0][]const u8{};

    const lib_unit_tests = b.addTest(.{
        .root_module = vector_mod,
        .filters = test_filters,
    });
    lib_unit_tests.step.dependOn(&download_sift.step);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const example_to_build = b.option(
        []const u8,
        "example",
        "Which example project to build, e.g. 'imessage'",
    ) orelse "";

    if (std.mem.eql(u8, example_to_build, "imessage")) {
        buildIMessageExample(b, target, optimize, vector_mod);
    }
}

// Builds the iMessage example, linking against the vector library as well as pulling
// in support for SQLite and some macOS-specific libraries (Natural language framework, Foundation).
fn buildIMessageExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vector_mod: *std.Build.Module,
) void {
    const imessage_mod = b.createModule(.{
        .root_source_file = b.path("examples/imessage.zig"),
        .target = target,
        .optimize = optimize,
    });

    const imessage = b.addExecutable(.{
        .name = "imessage",
        .root_module = imessage_mod,
    });
    imessage.root_module.addImport("vector", vector_mod);

    // Compile & link against the SQLite amalgamation.
    // TODO might be able to use the system SQLite library instead
    // if that is available, which should be the case on macOS.
    const sqlite = buildSqlite(b, target, optimize);
    imessage.linkLibrary(sqlite.compile_step);
    imessage.addIncludePath(sqlite.include_path);

    // We also need to link against macOS-specific frameworks.
    imessage.linkFramework("CoreFoundation");
    imessage.linkFramework("NaturalLanguage");

    // And because macOS APIs are hard to work with, objc provides a nice
    // bridge to use Objective-C APIs in Zig.
    const objc_dep = b.lazyDependency("objc", .{}).?;
    imessage.root_module.addImport("objc", objc_dep.module("objc"));

    b.installArtifact(imessage);
}

const SqliteDep = struct {
    compile_step: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
};

/// Compiles the SQLite amalgamation and provides a dependency for it.
/// This is used by the iMessage example to link against SQLite.
///
/// Note: This uses a lazy dependency, so SQLite will only be downloaded/compiled when needed.
fn buildSqlite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) SqliteDep {
    const dep = b.lazyDependency("sqlite", .{}).?;
    const lib = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = target,
        .optimize = optimize,
    });
    lib.addIncludePath(dep.path("."));
    lib.addCSourceFile(.{
        .file = dep.path("sqlite3.c"),
        .flags = &[_][]const u8{
            "-std=c99",
        },
    });
    lib.linkLibC();
    lib.installHeader(dep.path("sqlite3.h"), "sqlite3.h");
    b.installArtifact(lib);
    return .{
        .compile_step = lib,
        .include_path = dep.path("."),
    };
}
