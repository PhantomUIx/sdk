const std = @import("std");

const AvailableDep = struct { []const u8, []const u8 };
const AvailableDeps = []const AvailableDep;

pub const PhantomModule = struct {
    // TODO: expected version of core and sdk
    provides: ?Provides = null,
    dependencies: ?[]const []const u8 = null,

    pub const Provides = struct {
        scenes: ?[]const []const u8 = null,
        displays: ?[]const []const u8 = null,

        pub fn value(self: Provides, kind: std.meta.FieldEnum(Provides)) []const []const u8 {
            return (switch (kind) {
                .scenes => self.scenes,
                .displays => self.displays,
            }) orelse &[_][]const u8{};
        }

        pub fn count(self: Provides, kind: std.meta.FieldEnum(Provides)) usize {
            return self.value(kind).len;
        }
    };

    pub fn getProvider(self: PhantomModule) Provides {
        return if (self.provides) |value| value else .{};
    }

    pub fn getDependencies(self: PhantomModule) []const []const u8 {
        return self.dependencies orelse &[_][]const u8{};
    }
};

pub const availableDepenencies = blk: {
    const buildDeps = @import("root").dependencies;
    var count: usize = 0;
    for (buildDeps.root_deps) |dep| {
        const pkg = @field(buildDeps.packages, dep[1]);
        if (@hasDecl(pkg, "build_zig")) {
            const buildZig = pkg.build_zig;
            if (@hasDecl(buildZig, "phantomModule") and @TypeOf(@field(buildZig, "phantomModule")) == PhantomModule) {
                count += 1;
            }
        }
    }

    var i: usize = 0;
    var deps: [count]AvailableDep = undefined;
    for (buildDeps.root_deps) |dep| {
        const pkg = @field(buildDeps.packages, dep[1]);
        if (@hasDecl(pkg, "build_zig")) {
            const buildZig = pkg.build_zig;
            if (@hasDecl(buildZig, "phantomModule") and @TypeOf(@field(buildZig, "phantomModule")) == PhantomModule) {
                deps[i] = dep;
                i += 1;
            }
        }
    }
    break :blk deps;
};

pub fn TypeFor(comptime kind: std.meta.FieldEnum(PhantomModule.Provides)) type {
    const buildDeps = @import("root").dependencies;

    var fieldCount: usize = 0;
    for (buildDeps.root_deps) |dep| {
        const pkg = @field(buildDeps.packages, dep[1]);
        if (@hasDecl(pkg, "build_zig")) {
            const buildZig = pkg.build_zig;
            if (@hasDecl(buildZig, "phantomModule") and @TypeOf(@field(buildZig, "phantomModule")) == PhantomModule) {
                const mod = buildZig.phantomModule;
                fieldCount += mod.getProvider().count(kind);
            }
        }
    }

    if (fieldCount == 0) {
        return @Type(.{
            .Enum = .{
                .tag_type = u0,
                .fields = &.{},
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    }

    var fields: [fieldCount]std.builtin.Type.EnumField = undefined;
    var i: usize = 0;
    for (buildDeps.root_deps) |dep| {
        const pkg = @field(buildDeps.packages, dep[1]);
        if (@hasDecl(pkg, "build_zig")) {
            const buildZig = pkg.build_zig;
            if (@hasDecl(buildZig, "phantomModule") and @TypeOf(@field(buildZig, "phantomModule")) == PhantomModule) {
                const mod = buildZig.phantomModule;

                for (mod.getProvider().value(kind)) |name| {
                    fields[i] = .{
                        .name = name,
                        .value = i,
                    };
                    i += 1;
                }
            }
        }
    }

    return @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, fields.len - 1),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

fn importPkgCustom(b: *std.Build, name: []const u8, buildRoot: []const u8, comptime pkgId: []const u8, comptime exclude: []const []const u8, args: anytype) *std.Build.Dependency {
    const buildDeps = @import("root").dependencies;
    const pkg = @field(buildDeps.packages, pkgId);
    const deps: AvailableDeps = comptime blk: {
        var count: usize = 0;

        inline for (pkg.deps) |d| {
            inline for (exclude) |e| {
                if (!std.mem.eql(u8, d[0], e)) {
                    count += 1;
                    break;
                }
            }
        }
        var deps: [count]AvailableDep = undefined;

        var i: usize = 0;
        inline for (pkg.deps) |d| {
            inline for (exclude) |e| {
                if (!std.mem.eql(u8, d[0], e)) {
                    deps[i] = d;
                    i += 1;
                    break;
                }
            }
        }
        break :blk &deps;
    };

    return b.dependencyInner(name, buildRoot, if (@hasDecl(pkg, "build_zig")) pkg.build_zig else null, deps, args);
}

fn importPkg(b: *std.Build, name: []const u8, comptime pkgId: []const u8, args: anytype) *std.Build.Dependency {
    const buildDeps = @import("root").dependencies;
    const pkg = @field(buildDeps.packages, pkgId);
    return b.dependencyInner(name, pkg.build_root, if (@hasDecl(pkg, "build_zig")) pkg.build_zig else null, pkg.deps, args);
}

pub fn Dependencies() type {
    var fields: [availableDepenencies.len]std.builtin.Type.StructField = undefined;

    for (availableDepenencies, &fields, 0..) |dep, *field, i| {
        field.* = .{
            .name = dep[0],
            .type = *std.Build.Dependency,
            .default_value = null,
            .is_comptime = false,
            .alignment = i,
        };
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn dependencies(b: *std.Build, args: anytype) Dependencies() {
    var self: Dependencies() = undefined;

    inline for (availableDepenencies) |dep| {
        @field(self, dep[0]) = importPkg(b, dep[0], dep[1], args);
    }
    return self;
}

inline fn doesExist(path: []const u8, flags: std.fs.File.OpenFlags) bool {
    std.fs.accessAbsolute(path, flags) catch return false;
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const no_importer = b.option(bool, "no-importer", "disables the import system (not recommended)") orelse false;
    const modulesRaw = b.option([]const []const u8, "modules", "List of modules") orelse &[_][]const u8{
        "display.backends",
        "gpu.backends",
        "painting.image.formats",
        "scene.backends",
        "i18n",
    };

    if (no_importer) return;

    const deps = dependencies(b, .{
        .target = target,
        .optimize = optimize,
        .@"no-importer" = true,
    });

    const gen = b.addWriteFiles();
    var importer_data = std.ArrayList(u8).init(b.allocator);
    defer importer_data.deinit();

    // TODO: as all modules are expected to follow the same layout as core,
    // we can do a file/directory check for specific files.
    // However, there could be some exceptions...
    for (modulesRaw) |module| {
        var modSplit = std.mem.splitAny(u8, module, ".");

        while (modSplit.next()) |el| {
            importer_data.writer().print(
                \\pub const {s} = struct {{
            , .{el}) catch |e| @panic(@errorName(e));
        }

        inline for (availableDepenencies) |dep| {
            importer_data.writer().print(
                \\pub usingnamespace blk: {{
                \\    const imports = @import("{s}");
            , .{dep[0]}) catch |e| @panic(@errorName(e));

            modSplit.reset();
            var i: usize = 0;
            while (modSplit.next()) |el| {
                const end = if (modSplit.index) |x| x + 1 else module.len - 1;
                const y = std.mem.lastIndexOfLinear(u8, module[0..end], ".") orelse end;
                const d = if (i < 1) "" else b.fmt(".{s}", .{module[0..y]});

                importer_data.writer().print(
                    \\if (@hasDecl(imports{s}, "{s}")) {{
                , .{ d, el }) catch |e| @panic(@errorName(e));

                i += 1;
            }

            importer_data.writer().print(
                \\break :blk imports.{s};
            , .{module}) catch |e| @panic(@errorName(e));

            modSplit.reset();
            while (modSplit.next()) |_| {
                importer_data.writer().print(
                    \\}}
                , .{}) catch |e| @panic(@errorName(e));
            }

            importer_data.writer().print(
                \\    break :blk struct {{}};
                \\}};
            , .{}) catch |e| @panic(@errorName(e));
        }

        modSplit.reset();
        while (modSplit.next()) |_| {
            importer_data.writer().print(
                \\}};
            , .{}) catch |e| @panic(@errorName(e));
        }
    }

    var importer_deps: [availableDepenencies.len]std.Build.ModuleDependency = undefined;
    inline for (availableDepenencies, 0..) |dep, i| {
        const pkg = @field(@import("root").dependencies.packages, dep[1]);
        const imported_dep = @field(deps, dep[0]);
        const origModule = imported_dep.module(dep[0]);

        // TODO: expected version check

        var depsList = std.ArrayList(std.Build.ModuleDependency).init(b.allocator);
        errdefer depsList.deinit();

        const phantomCore = blk: {
            inline for (pkg.deps) |childDeps| {
                if (std.mem.eql(u8, childDeps[0], "phantom")) {
                    const subpkg = @field(@import("root").dependencies.packages, childDeps[1]);
                    // TODO: expected version check
                    const newPath = b.pathJoin(&.{ b.cache_root.path.?, "p", std.fs.path.basename(dep[1]), std.fs.path.basename(childDeps[1]) });

                    if (!doesExist(std.fs.path.dirname(newPath).?, .{})) {
                        std.fs.cwd().makePath(std.fs.path.dirname(newPath).?) catch |e| std.debug.panic("Failed to create path {s}: {s}", .{ std.fs.path.dirname(newPath).?, @errorName(e) });
                    }

                    if (!doesExist(newPath, .{})) {
                        std.fs.symLinkAbsolute(subpkg.build_root, newPath, .{ .is_directory = true }) catch |e| std.debug.panic("Failed to create symlink {s}: {s}", .{ newPath, @errorName(e) });
                    }
                    break :blk importPkgCustom(origModule.builder, childDeps[0], newPath, childDeps[1], &.{"phantom-sdk"}, .{
                        .target = target,
                        .optimize = optimize,
                        .@"no-importer" = true,
                    });
                }
            }
            break :blk null;
        };

        if (phantomCore) |m| {
            depsList.append(.{
                .name = "phantom",
                .module = m.module("phantom"),
            }) catch @panic("OOM");
        }

        for (pkg.build_zig.phantomModule.getDependencies()) |depName| {
            if (std.mem.eql(u8, depName, "phantom")) continue;

            depsList.append(.{
                .name = depName,
                .module = origModule.builder.dependency(depName, .{
                    .target = target,
                    .optimize = optimize,
                }).module(depName),
            }) catch @panic("OOM");
        }

        importer_deps[i] = .{
            .name = dep[0],
            .module = imported_dep.builder.createModule(.{
                .source_file = origModule.source_file,
                .dependencies = depsList.items,
            }),
        };
    }

    const importer_gen = gen.add("phantom.imports.zig", importer_data.items);
    _ = b.addModule("phantom.imports", .{
        .source_file = importer_gen,
        .dependencies = &importer_deps,
    });

    b.getInstallStep().dependOn(&gen.step);
}
