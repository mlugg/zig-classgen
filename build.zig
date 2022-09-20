const std = @import("std");
const ClassGenerator = @import("generate.zig").ClassGenerator;

pub fn addPackage(b: *std.build.Builder, lib: *std.build.LibExeObjStep, pkg_name: []const u8, dir: []const u8) !void {
    const out_path = b.fmt("{s}/{s}.zig", .{ b.cache_root, pkg_name });

    const step = try b.allocator.create(ClassGenStep);
    step.* = .{
        .b = b,
        .step = std.build.Step.init(.custom, b.fmt("ClassGen {s}", .{dir}), b.allocator, ClassGenStep.make),
        .dir = dir,
        .out_file = .{ .step = &step.step, .path = out_path },
        .abi = switch (lib.target.getOsTag()) {
            .linux, .macos => .itanium,
            .windows => .msvc,
            else => return error.UnsupportedOs,
        },
    };

    const internal_pkg = std.build.Pkg{
        .name = "cg_internal",
        .source = .{ .path = comptime thisDir() ++ "/cg_internal.zig" },
    };

    const pkg = std.build.Pkg{
        .name = pkg_name,
        .source = .{ .generated = &step.out_file },
        .dependencies = &.{internal_pkg},
    };

    lib.addPackage(pkg);
}

const ClassGenStep = struct {
    b: *std.build.Builder,
    step: std.build.Step,
    dir: []const u8,
    out_file: std.build.GeneratedFile,
    abi: ClassGenerator.Abi,

    pub fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(ClassGenStep, "step", step);

        var gen = ClassGenerator.init(self.b.allocator, self.abi);

        const dir = try std.fs.cwd().openIterableDir(self.dir, .{});
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .File) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
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
