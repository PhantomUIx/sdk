const std = @import("std");

const AvailableDep = struct { []const u8, []const u8 };
const AvailableDeps = []const AvailableDep;

pub const PhantomModule = struct {
    provides: ?Provides = null,
    dependencies: ?[][]const u8 = null,

    pub const Provides = struct {
        scenes: ?[][]const u8 = null,
        displays: ?[][]const u8 = null,

        pub fn value(self: Provides, kind: std.meta.FieldEnum(Provides)) [][]const u8 {
            return (switch (kind) {
                .scenes => self.scenes,
                .displays => self.displays,
                else => null,
            }) orelse &[_][]const u8{};
        }

        pub fn count(self: Provides, kind: std.meta.FieldEnum(Provides)) bool {
            return self.value(kind).len;
        }
    };

    pub fn getProvider(self: PhantomModule) Provides {
        return if (self.provides) |value| value else .{};
    }
};

pub const availableDepenencies = blk: {
    const buildDeps = @import("root").dependencies;
    var count: usize = 0;
    for (buildDeps.root_deps) |dep| {
        const pkg = @field(buildDeps.packages, dep[1]);
        if (pkg.build_zig != null) {
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
        if (pkg.build_zig != null) {
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
        if (pkg.build_zig != null) {
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
        if (pkg.build_zig != null) {
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const modulesRaw = b.option([]const []const u8, "modules", "List of modules") orelse &[_][]const u8{
        "display.backends",
        "scene.backends",
        "i18n",
    };

    const deps = dependencies(b, .{
        .target = target,
        .optimize = optimize,
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

    const phantomCore = blk: {
        const buildDeps = @import("root").dependencies;
        for (buildDeps.root_deps) |dep| {
            if (std.mem.eql(u8, dep[0], "phantom")) {
                break :blk importPkg(b, dep[0], dep[1], .{
                    .target = target,
                    .optimize = optimize,
                    .no_importer = true,
                });
            }
        }

        @panic("Cannot find Phantom UI core");
    };

    var importer_deps: [availableDepenencies.len]std.Build.ModuleDependency = undefined;
    inline for (availableDepenencies, 0..) |dep, i| {
        const pkg = @field(@import("root").dependencies.packages, dep[1]);
        const imported_dep = @field(deps, dep[0]);
        const origModule = imported_dep.module(dep[0]);

        const depsList = std.ArrayList(std.Build.ModuleDependency).init(b.allocator);
        errdefer depsList.deinit();

        depsList.append(.{
            .name = "phantom",
            .module = phantomCore.module("phantom"),
        }) catch @panic("OOM");

        for (pkg.build_zig.phantomModule.getDependencies()) |depName| {
            const buildDeps = @import("root").dependencies;
            var found = false;
            for (buildDeps.root_deps) |d| {
                if (std.mem.eql(u8, d[0], depName)) {
                    const depDep = importPkg(b, d[0], d[1], .{
                        .target = target,
                        .optimize = optimize,
                        .no_importer = true,
                    });

                    depsList.append(depDep.module(d[0])) catch @panic("OOM");
                    found = true;
                    break;
                }
            }

            if (!found) std.debug.panic("Could not find dependency {s} for {s}", .{ depName, dep[0] });
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
