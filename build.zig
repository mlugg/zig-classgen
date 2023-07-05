const std = @import("std");
const ClassGenerator = @import("generate.zig").ClassGenerator;

pub fn addModule(b: *std.Build, lib: *std.Build.Step.Compile, mod_name: []const u8, dir: []const u8) void {
    const out_path = b.fmt("{}/{s}.zig", .{ b.cache_root, mod_name });

    const step = b.allocator.create(ClassGenStep) catch unreachable;
    step.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("ClassGen {s}", .{dir}),
            .owner = b,
            .makeFn = ClassGenStep.make,
        }),
        .mod_name = mod_name,
        .b = b,
        .dir = dir,
        .out_file = .{ .step = &step.step, .path = out_path },
        .abi = switch (lib.target.getOsTag()) {
            .linux, .macos => .itanium,
            .windows => .msvc,
            else => unreachable,
        },
    };

    const internal_mod = b.createModule(.{
        .source_file = .{ .path = comptime thisDir() ++ "/cg_internal.zig" },
    });

    const rec_mod = b.createModule(.{
        .source_file = .{ .path = b.fmt("{s}/extra.zig", .{dir}) },
    });

    const main_mod = b.createModule(.{
        .source_file = .{ .generated = &step.out_file },
        .dependencies = &.{
            .{ .name = "cg_internal", .module = internal_mod },
            .{ .name = "cg_rec", .module = rec_mod },
        },
    });

    rec_mod.dependencies.put(mod_name, main_mod) catch @panic("OOM");

    lib.addModule(mod_name, main_mod);
}

const ClassGenStep = struct {
    b: *std.Build,
    step: std.Build.Step,
    dir: []const u8,
    mod_name: []const u8,
    out_file: std.Build.GeneratedFile,
    abi: ClassGenerator.Abi,

    pub fn make(step: *std.Build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(ClassGenStep, "step", step);

        var gen = ClassGenerator.init(self.b.allocator, self.abi, self.mod_name);

        const dir = try std.fs.cwd().openIterableDir(self.dir, .{});
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            if (std.mem.endsWith(u8, entry.name, ".zig")) continue;
            try gen.addClassFile(dir.dir, entry.name);
        }

        const source = try gen.finish();

        const f = try std.fs.cwd().createFile(self.out_file.path.?, .{});
        defer f.close();
        try f.writeAll(source);
    }
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
