const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_integration_tests = b.option(bool, "run-integration", "Run network integration tests") orelse false;
    const build_info = createBuildInfoOptions(b, run_integration_tests);
    const package_snapshot = addPackageSnapshot(b);
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    // Library module for external packages
    const openapi2zig_mod = b.addModule("openapi2zig", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    openapi2zig_mod.addIncludePath(b.path("src"));
    openapi2zig_mod.addOptions("build_info", build_info);
    openapi2zig_mod.addImport("yaml", yaml_dep.module("yaml"));

    // CLI executable
    const exe_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_root_module.addOptions("build_info", build_info);
    exe_root_module.addImport("yaml", yaml_dep.module("yaml"));
    addApplicationIcon(b, exe_root_module);
    const exe = b.addExecutable(.{
        .name = "openapi2zig",
        .root_module = exe_root_module,
    });
    exe.root_module.addImport("openapi2zig", openapi2zig_mod);
    b.installArtifact(exe);

    // Static library for linking
    const lib_root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_root_module.addOptions("build_info", build_info);
    lib_root_module.addImport("yaml", yaml_dep.module("yaml"));
    const lib = b.addLibrary(.{
        .name = "openapi2zig",
        .root_module = lib_root_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Cross-compile builds for every supported platform
    const supported_targets = [_][]const u8{
        "x86_64-linux",
        "aarch64-linux",
        "x86_64-windows",
        "x86_64-macos",
        "aarch64-macos",
    };
    const build_all_step = b.step("build-all", "Build for all supported platforms");
    for (supported_targets) |target_triple| {
        const cross_target = b.resolveTargetQuery(
            std.Target.Query.parse(.{ .arch_os_abi = target_triple }) catch |err| {
                std.log.err("invalid build-all target '{s}': {s}", .{
                    target_triple,
                    @errorName(err),
                });
                @panic("invalid build-all target");
            },
        );
        const target_yaml_dep = b.dependency("yaml", .{
            .target = cross_target,
            .optimize = optimize,
        });

        const cross_lib_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        cross_lib_module.addIncludePath(b.path("src"));
        cross_lib_module.addOptions("build_info", createBuildInfoOptions(b, run_integration_tests));
        cross_lib_module.addImport("yaml", target_yaml_dep.module("yaml"));

        const cross_exe_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        cross_exe_module.addOptions("build_info", createBuildInfoOptions(b, run_integration_tests));
        cross_exe_module.addImport("yaml", target_yaml_dep.module("yaml"));
        cross_exe_module.addImport("openapi2zig", cross_lib_module);
        addApplicationIcon(b, cross_exe_module);

        const cross_exe = b.addExecutable(.{
            .name = "openapi2zig",
            .root_module = cross_exe_module,
        });
        const install_cross_exe = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = target_triple } },
        });
        build_all_step.dependOn(&install_cross_exe.step);
    }

    addInstallStep(b, target, build_info, yaml_dep, "install-release", "Build ReleaseSmall and install to $HOME/.local/bin", .ReleaseSmall);
    addInstallStep(b, target, build_info, yaml_dep, "install-release-safe", "Build ReleaseSafe and install to $HOME/.local/bin", .ReleaseSafe);
    addInstallStep(b, target, build_info, yaml_dep, "install-release-fast", "Build ReleaseFast and install to $HOME/.local/bin", .ReleaseFast);
    addInstallStep(b, target, build_info, yaml_dep, "install-debug", "Build Debug and install to $HOME/.local/bin", .Debug);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_generate_v3_cmd = b.addRunArtifact(exe);
    run_generate_v3_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/generated_v3.zig",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_step = b.step("run-generate-v3", "Run the app with generate command");
    run_generate_v3_step.dependOn(&run_generate_v3_cmd.step);

    const run_generate_v3_multi_cmd = b.addRunArtifact(exe);
    run_generate_v3_multi_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/multi",
        "--multiple-files",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_multi_step = b.step("run-generate-v3-multi", "Generate multiple output files (models, runtime, client)");
    run_generate_v3_multi_step.dependOn(&run_generate_v3_multi_cmd.step);

    const run_generate_v3_multiclient_tag_cmd = b.addRunArtifact(exe);
    run_generate_v3_multiclient_tag_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/generated_v3_multiclient_tag.zig",
        "--multiple-clients",
        "PerTag",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_multiclient_tag_step = b.step("run-generate-v3-multiclient-tag", "Generate per-tag client structs from petstore");
    run_generate_v3_multiclient_tag_step.dependOn(&run_generate_v3_multiclient_tag_cmd.step);

    const run_generate_v3_multiclient_endpoint_cmd = b.addRunArtifact(exe);
    run_generate_v3_multiclient_endpoint_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/generated_v3_multiclient_endpoint.zig",
        "--multiple-clients",
        "PerEndpoint",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_multiclient_endpoint_step = b.step("run-generate-v3-multiclient-endpoint", "Generate per-endpoint client structs from petstore");
    run_generate_v3_multiclient_endpoint_step.dependOn(&run_generate_v3_multiclient_endpoint_cmd.step);

    const run_generate_v3_multiclient_tag_multi_cmd = b.addRunArtifact(exe);
    run_generate_v3_multiclient_tag_multi_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/multiple-clients/tag",
        "--multiple-files",
        "--multiple-clients",
        "PerTag",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_multiclient_tag_multi_step = b.step("run-generate-v3-multiclient-tag-multi", "Generate per-tag multi-file client from petstore");
    run_generate_v3_multiclient_tag_multi_step.dependOn(&run_generate_v3_multiclient_tag_multi_cmd.step);

    const run_generate_v3_multiclient_endpoint_multi_cmd = b.addRunArtifact(exe);
    run_generate_v3_multiclient_endpoint_multi_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/multiple-clients/endpoint",
        "--multiple-files",
        "--multiple-clients",
        "PerEndpoint",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_multiclient_endpoint_multi_step = b.step("run-generate-v3-multiclient-endpoint-multi", "Generate per-endpoint multi-file client from petstore");
    run_generate_v3_multiclient_endpoint_multi_step.dependOn(&run_generate_v3_multiclient_endpoint_multi_cmd.step);

    const run_generate_v3_tagfilter_cmd = b.addRunArtifact(exe);
    run_generate_v3_tagfilter_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/generated_v3_tagfilter.zig",
        "--tag",
        "pet",
        "--tag",
        "store",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_tagfilter_step = b.step("run-generate-v3-tagfilter", "Generate petstore client filtered by the pet and store tags");
    run_generate_v3_tagfilter_step.dependOn(&run_generate_v3_tagfilter_cmd.step);

    const run_generate_v3_params_struct_cmd = b.addRunArtifact(exe);
    run_generate_v3_params_struct_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.json",
        "-o",
        "generated/generated_v3_params_struct.zig",
        "--parameters-as-struct",
        "--resource-wrappers",
        "none",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_params_struct_step = b.step("run-generate-v3-params-struct", "Generate petstore client with parameters wrapped in an options struct");
    run_generate_v3_params_struct_step.dependOn(&run_generate_v3_params_struct_cmd.step);

    const run_generate_v2_cmd = b.addRunArtifact(exe);
    run_generate_v2_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v2.0/petstore.json",
        "-o",
        "generated/generated_v2.zig",
        "--base-url",
        "https://petstore.swagger.io/v2",
    });
    const run_generate_v2_step = b.step("run-generate-v2", "Run the app with generate command");
    run_generate_v2_step.dependOn(&run_generate_v2_cmd.step);

    const run_generate_v2_yaml_cmd = b.addRunArtifact(exe);
    run_generate_v2_yaml_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v2.0/petstore.yaml",
        "-o",
        "generated/generated_v2_yaml.zig",
        "--base-url",
        "https://petstore.swagger.io/v2",
    });
    const run_generate_v2_yaml_step = b.step("run-generate-v2-yaml", "Run the app with generate command for Swagger v2.0 YAML");
    run_generate_v2_yaml_step.dependOn(&run_generate_v2_yaml_cmd.step);

    const run_generate_v32_cmd = b.addRunArtifact(exe);
    run_generate_v32_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.2/petstore.json",
        "-o",
        "generated/generated_v32.zig",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v32_step = b.step("run-generate-v32", "Run the app with generate command for OpenAPI v3.2");
    run_generate_v32_step.dependOn(&run_generate_v32_cmd.step);

    const run_generate_v31_cmd = b.addRunArtifact(exe);
    run_generate_v31_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/webhook-example.json",
        "-o",
        "generated/generated_v31.zig",
    });
    const run_generate_v31_step = b.step("run-generate-v31", "Run the app with generate command for OpenAPI v3.1");
    run_generate_v31_step.dependOn(&run_generate_v31_cmd.step);

    const run_generate_v31_yaml_cmd = b.addRunArtifact(exe);
    run_generate_v31_yaml_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/webhook-example.yaml",
        "-o",
        "generated/generated_v31_yaml.zig",
    });
    const run_generate_v31_yaml_step = b.step("run-generate-v31-yaml", "Run the app with generate command for OpenAPI v3.1 YAML");
    run_generate_v31_yaml_step.dependOn(&run_generate_v31_yaml_cmd.step);

    const run_generate_v3_yaml_cmd = b.addRunArtifact(exe);
    run_generate_v3_yaml_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/petstore.yaml",
        "-o",
        "generated/generated_v3_yaml.zig",
        "--base-url",
        "https://petstore3.swagger.io/api/v3",
    });
    const run_generate_v3_yaml_step = b.step("run-generate-v3-yaml", "Run the app with generate command for OpenAPI v3.0 YAML");
    run_generate_v3_yaml_step.dependOn(&run_generate_v3_yaml_cmd.step);

    const run_generate_lmstudio_json_cmd = b.addRunArtifact(exe);
    run_generate_lmstudio_json_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/lmstudio.json",
        "-o",
        "generated/lmstudio.zig",
        "--base-url",
        "http://localhost:1234",
    });
    const run_generate_lmstudio_json_step = b.step("run-generate-lmstudio", "Run the app with generate command for LM Studio OpenAPI JSON");
    run_generate_lmstudio_json_step.dependOn(&run_generate_v3_yaml_cmd.step);

    const run_generate_lmstudio_multi_cmd = b.addRunArtifact(exe);
    run_generate_lmstudio_multi_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/lmstudio.json",
        "-o",
        "generated/lmstudio-multi",
        "--multiple-files",
        "--file-name",
        "models=types.zig",
        "--file-name",
        "runtime=http.zig",
        "--file-name",
        "client=api.zig",
        "--base-url",
        "http://localhost:1234",
    });
    const run_generate_lmstudio_multi_step = b.step("run-generate-lmstudio-multi", "Generate multi-file LM Studio client with custom file names");
    run_generate_lmstudio_multi_step.dependOn(&run_generate_lmstudio_multi_cmd.step);

    const run_generate_anthropic_json_cmd = b.addRunArtifact(exe);
    run_generate_anthropic_json_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/anthropic.json",
        "-o",
        "generated/anthropic.zig",
        "--base-url",
        "http://localhost:1234",
    });

    const run_generate_anthropic_json_step = b.step("run-generate-anthropic", "Run the app with generate command for Anthropic OpenAPI JSON");
    run_generate_anthropic_json_step.dependOn(&run_generate_lmstudio_json_cmd.step);

    const run_generate_openai_json_cmd = b.addRunArtifact(exe);
    run_generate_openai_json_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.1/openai.json",
        "-o",
        "generated/openai.zig",
    });

    const run_generate_openai_json_step = b.step("run-generate-openai", "Run the app with generate command for OpenAI OpenAPI JSON");
    run_generate_openai_json_step.dependOn(&run_generate_openai_json_cmd.step);

    const run_generate_github_multi_cmd = b.addRunArtifact(exe);
    run_generate_github_multi_cmd.addArgs(&.{
        "generate",
        "-i",
        "openapi/v3.0/github.json",
        "-o",
        "examples/github",
        "--multiple-files",
        "--tag",
        "issues",
        "--tag",
        "pulls",
        "--base-url",
        "https://api.github.com",
    });
    const run_generate_github_multi_step = b.step("run-generate-github-multi", "Generate multi-file GitHub client filtered by the issues and pulls tags");
    run_generate_github_multi_step.dependOn(&run_generate_github_multi_cmd.step);

    const run_generate = b.step("run-generate", "Run the app with generate commands");
    run_generate.dependOn(&run_generate_v3_cmd.step);
    run_generate.dependOn(&run_generate_v3_multi_cmd.step);
    run_generate.dependOn(&run_generate_v3_multiclient_tag_cmd.step);
    run_generate.dependOn(&run_generate_v3_multiclient_endpoint_cmd.step);
    run_generate.dependOn(&run_generate_v3_multiclient_tag_multi_cmd.step);
    run_generate.dependOn(&run_generate_v3_multiclient_endpoint_multi_cmd.step);
    run_generate.dependOn(&run_generate_v3_tagfilter_cmd.step);
    run_generate.dependOn(&run_generate_v3_params_struct_cmd.step);
    run_generate.dependOn(&run_generate_v3_yaml_cmd.step);
    run_generate.dependOn(&run_generate_v2_cmd.step);
    run_generate.dependOn(&run_generate_v2_yaml_cmd.step);
    run_generate.dependOn(&run_generate_v32_cmd.step);
    run_generate.dependOn(&run_generate_v31_cmd.step);
    run_generate.dependOn(&run_generate_v31_yaml_cmd.step);
    run_generate.dependOn(&run_generate_lmstudio_json_cmd.step);
    run_generate.dependOn(&run_generate_lmstudio_multi_cmd.step);
    run_generate.dependOn(&run_generate_anthropic_json_cmd.step);
    run_generate.dependOn(&run_generate_openai_json_cmd.step);
    run_generate.dependOn(&run_generate_github_multi_cmd.step);

    const run_generated_main_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "generated/main.zig" });
    run_generated_main_cmd.step.dependOn(run_generate);

    const run_generated_lmstudio_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "generated/lmstudio_example.zig" });
    run_generated_lmstudio_cmd.step.dependOn(&run_generated_main_cmd.step);

    // The GitHub client is a library, not a runnable example, so it is compiled
    // rather than run. Building it after regeneration proves the multi-file and
    // tag-filtered output of a large specification still compiles.
    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compile_examples.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_example_tests = b.addRunArtifact(example_tests);
    run_example_tests.step.dependOn(&run_generate_github_multi_cmd.step);

    const run_generated = b.step("run-generated", "Regenerate and run generated/main.zig and lmstudio_example.zig, and build the GitHub client");
    run_generated.dependOn(&run_generated_lmstudio_cmd.step);
    run_generated.dependOn(&run_example_tests.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addOptions("build_info", build_info);
    tests_mod.addImport("yaml", yaml_dep.module("yaml"));

    const exe_unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });
    exe_unit_tests.root_module.addImport("openapi2zig", openapi2zig_mod);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const coverage_exe = b.addTest(.{
        .name = "test",
        .root_module = tests_mod,
        .use_llvm = true,
    });
    coverage_exe.root_module.addImport("openapi2zig", openapi2zig_mod);
    b.installArtifact(coverage_exe);
    const test_coverage_step = b.step("test-coverage", "Build test binary for coverage");
    test_coverage_step.dependOn(b.getInstallStep());

    const generated_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("generated/compile_generated.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_generated_tests = b.addRunArtifact(generated_tests);
    test_step.dependOn(&run_generated_tests.step);

    const multi_generated_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("generated/compile_multi_generated.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_multi_generated_tests = b.addRunArtifact(multi_generated_tests);
    test_step.dependOn(&run_multi_generated_tests.step);

    const test_package_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    test_package_cmd.setCwd(package_snapshot.path(b, "examples/package_consumer"));
    const test_package_step = b.step("test-package", "Build downstream package consumer example");
    test_package_step.dependOn(&test_package_cmd.step);
    test_step.dependOn(&test_package_cmd.step);

    const test_artifact = b.addInstallArtifact(
        exe_unit_tests,
        .{ .dest_dir = .{ .override = .{ .custom = "tests" } } },
    );
    const install_test_step = b.step("install_test", "Create test binaries for debugging");
    install_test_step.dependOn(&test_artifact.step);
}

fn createBuildInfoOptions(b: *std.Build, run_integration_tests: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    const io = b.graph.io;
    // Everything here describes *this* package. A dependent's build runs with
    // its own directory as the working directory, so read the version and the
    // git metadata from the package root rather than from wherever the build
    // was started; otherwise generated headers claim the consumer's version.
    const build_root = buildRootPath(b);
    const package_version = getPackageVersion(b, io) orelse "unknown";
    // Only ask git when the package root is a checkout of its own. A fetched
    // package is unpacked inside the dependent's project, where git would
    // happily describe *that* repository instead of this one.
    const git_checkout = isGitCheckout(b, build_root);
    // The build configuration is cached, and nothing tells the cache that a
    // commit or a new tag changes what git reports. Poisoning it makes `zig
    // build` configure afresh every time in a checkout; a fetched package asks
    // git nothing and stays cacheable.
    if (git_checkout) b.graph.poisonCache();
    const git_tag = (if (git_checkout)
        getGitOutput(b.allocator, io, &.{ "git", "-C", build_root, "describe", "--tags", "--abbrev=0" })
    else
        null) orelse b.fmt("v{s}", .{package_version});
    const git_commit = (if (git_checkout)
        getGitOutput(b.allocator, io, &.{ "git", "-C", build_root, "rev-parse", "--short", "HEAD" })
    else
        null) orelse "unknown";
    const version = if (std.mem.startsWith(u8, git_tag, "v")) git_tag[1..] else git_tag;

    // Everything here has to be a function of the source, never of the clock.
    // These options become a generated file that is an input to every module
    // built from this package, so a value that changes between two builds of
    // the same tree gives that file a new hash, and nothing compiled from it
    // -- nor anything downstream of *that*, such as a dependent's codegen step
    // and whatever it emits -- can ever come out of the cache again. A build
    // date is the obvious way to get this wrong: it cost zig-netbox a full
    // regeneration of its 6.5 MB client on every single build.
    options.addOption([]const u8, "VERSION", version);
    options.addOption([]const u8, "GIT_TAG", git_tag);
    options.addOption([]const u8, "GIT_COMMIT", git_commit);
    options.addOption(bool, "RUN_INTEGRATION_TESTS", run_integration_tests);

    return options;
}

/// Copies the package's files into a directory of their own, so that the
/// package consumer example builds against the package as a dependent sees it.
/// The file list comes from git at make time, so the step always runs.
fn addPackageSnapshot(b: *std.Build) std.Build.LazyPath {
    const snapshot = b.addRunArtifact(addHostTool(b, "package_snapshot", "tools/package_snapshot.zig"));
    snapshot.setName("prepare-package-snapshot");
    snapshot.setCwd(b.path("."));
    snapshot.has_side_effects = true;
    return snapshot.addOutputDirectoryArg("package-snapshot");
}

/// Builds one of the programs in `tools/` for the machine running the build.
fn addHostTool(b: *std.Build, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
}

/// The package root as a path git can be pointed at.
fn buildRootPath(b: *std.Build) []const u8 {
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    return if (root.len == 0) "." else root;
}

/// True when `dir` holds a `.git` of its own: a directory in a normal clone,
/// a file in a worktree. Both mean git commands run there describe this
/// package rather than some repository it happens to sit inside.
fn isGitCheckout(b: *std.Build, dir: []const u8) bool {
    const dot_git = b.pathJoin(&.{ dir, ".git" });
    std.Io.Dir.cwd().access(b.graph.io, dot_git, .{}) catch return false;
    return true;
}

fn getPackageVersion(b: *std.Build, io: std.Io) ?[]const u8 {
    const allocator = b.allocator;
    b.dependOnFileContents(b.path("build.zig.zon"));
    const path = b.root.joinString(allocator, "build.zig.zon") catch @panic("OOM");
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const version_start = start + marker.len;
    const version_end = std.mem.indexOfScalarPos(u8, content, version_start, '"') orelse return null;
    return content[version_start..version_end];
}

fn addInstallStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    build_info: *std.Build.Step.Options,
    yaml_dep: *std.Build.Dependency,
    step_name: []const u8,
    description: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = addOpenApi2ZigExecutable(b, "openapi2zig", target, optimize, build_info, yaml_dep);
    const install_step = b.step(step_name, description);
    const install = b.addRunArtifact(addHostTool(b, "install_release", "tools/install_release.zig"));
    install.setName(b.fmt("install {s} ({t})", .{ exe.out_filename, optimize }));
    install.addArtifactArg2(exe, .{ .make_absolute = true });
    install.addDirectoryArg2(b.graph.path(.install_prefix, ""), .{ .make_absolute = true });
    install.addFileArg2(b.path("build.zig"), .{ .make_absolute = true });
    install.has_side_effects = true;
    install_step.dependOn(&install.step);
}

fn addOpenApi2ZigExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_info: *std.Build.Step.Options,
    yaml_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_info", build_info);
    root_module.addImport("yaml", yaml_dep.module("yaml"));
    addApplicationIcon(b, root_module);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });

    const openapi2zig_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    openapi2zig_mod.addIncludePath(b.path("src"));
    openapi2zig_mod.addOptions("build_info", build_info);
    openapi2zig_mod.addImport("yaml", yaml_dep.module("yaml"));
    root_module.addImport("openapi2zig", openapi2zig_mod);

    return exe;
}

/// Embeds the application icon into the executable. Only PE/COFF binaries
/// have a resource table, so Zig ignores this for Linux and macOS targets.
fn addApplicationIcon(b: *std.Build, module: *std.Build.Module) void {
    module.addWin32ResourceFile(.{ .file = b.path("resources/openapi2zig.rc") });
}

fn getGitOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return std.mem.trim(u8, result.stdout, " \t\n\r");
            } else {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
}
