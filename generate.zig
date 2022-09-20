const std = @import("std");

const Class = @import("common.zig").Class;
const RawClass = @import("common.zig").RawClass;
const VirtualMethod = @import("common.zig").VirtualMethod;
const parseClassFile = @import("parse.zig").parseClassFile;

const Generator = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    abi: ClassGenerator.Abi,

    fn print(self: *Generator, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.writer().print(fmt, args);
    }

    fn begin(self: *Generator) !void {
        try self.print("const _internal = @import(\"cg_internal\");", .{});
        try self.print("const _Method = {s};", .{switch (self.abi) {
            .msvc => "@import(\"std\").builtin.CallingConvention.Thiscall",
            .itanium => "@import(\"std\").builtin.CallingConvention.C",
        }});
    }

    fn generateClass(self: *Generator, class: Class) !void {
        try self.print("pub const {s} = extern struct {{", .{class.name});

        const main_parent = switch (class.vtable) {
            .none => null,
            .new => blk: {
                try self.print("const _Vtable = extern struct {{", .{});
                try self.generateRemainingVtable(class, null);
                try self.print("}};", .{});
                break :blk null;
            },
            .inherited => |parent_vt_idx| blk: {
                const main_parent = class.parents[parent_vt_idx];
                try self.print("const _Vtable = extern struct {{ _vt_{s}: {s}._Vtable,", .{ main_parent.name, main_parent.name });
                try self.generateRemainingVtable(class, main_parent);
                try self.print("}};", .{});
                break :blk main_parent;
            },
        };

        try self.print("const _PostVtable = _internal.ConcatStructs(&.{{", .{});

        if (main_parent) |parent| {
            // No need to pad this parent, since it has a vtable so can't be standard layout
            try self.print("{s}._PostVtable,", .{parent.name});
        }

        for (class.parents) |parent| {
            if (parent == main_parent) continue;

            // We add dummy values to indicate the offset that certain base classes appear at
            try self.print("struct {{ _offset_to_{s}: extern struct {{}} }},", .{parent.name});

            if (parent.is_standard_layout) {
                try self.print("_internal.PadStruct({s}),", .{parent.name});
            } else {
                try self.print("{s},", .{parent.name});
            }
        }

        try self.print("_Fields,", .{});
        try self.print("}});", .{});

        try self.print("const _Fields = extern struct {{", .{});
        for (class.fields) |field| {
            try self.print("{s}: {},", .{ field.zig_name, field.zig_type });
        }
        try self.print("}};", .{});

        try self.print("data: _internal.ConcatStructs(&.{{", .{});
        if (class.vtable != .none) {
            try self.print("struct {{ _vt: *_Vtable }},", .{});
        }
        try self.print("_PostVtable,", .{});
        try self.print("}}),", .{});

        try self.generateWrapperMethods(class);
        try self.generateBaseCastMethod(class, main_parent);

        try self.print("}};", .{});
    }

    fn generateRemainingVtable(self: *Generator, class: Class, main_parent: ?*Class) !void {
        switch (self.abi) {
            .msvc => {
                var entries = std.StringArrayHashMap(std.ArrayList(*VirtualMethod)).init(self.allocator);
                for (class.vmethods) |*method| {
                    const result = try entries.getOrPut(method.dispatch_group);
                    if (!result.found_existing) {
                        // Even if we're not adding this dispatch, we need to create the group here
                        result.value_ptr.* = std.ArrayList(*VirtualMethod).init(self.allocator);
                    }

                    for (class.parents) |p| {
                        if (p.hasAnyMethod(method.*)) break;
                    } else {
                        try result.value_ptr.append(method);
                    }
                }

                for (entries.values()) |group| {
                    var i: usize = group.items.len;
                    while (i > 0) : (i -= 1) {
                        const method = group.items[i - 1];
                        try self.print("{s}: {},", .{ method.zig_name, method.zig_type });
                    }
                }
            },

            .itanium => {
                for (class.vmethods) |method| {
                    if (main_parent == null or !main_parent.?.hasMainMethod(method)) {
                        try self.print("{s}: {},", .{ method.zig_name, method.zig_type });
                    }
                }
            },
        }
    }

    fn generateWrapperMethods(self: *Generator, class: Class) !void {
        // TODO: variadic functions
        for (class.vmethods) |method| {
            if (method.zig_type == .named) {
                // This is a generated field for skipped methods rather than an actual named method, so don't generate a wrapper for it
                continue;
            }

            const override = for (class.parents) |p| {
                if (p.hasAnyMethod(method)) break true;
            } else false;

            if (override) {
                // Generating wrapper methods for overrides is really tricky so I simply will not
                continue;
            }

            try self.print("pub inline fn {s}(self: *{s}", .{ method.zig_name, class.name });
            for (method.args) |arg, i| {
                try self.print(", arg{}: {}", .{ i, arg });
            }
            try self.print(") {} {{", .{method.ret});
            try self.print("return self.data._vt.{s}(self", .{method.zig_name});
            for (method.args) |_, i| {
                try self.print(", arg{}", .{i});
            }
            try self.print("); }}", .{});
        }
    }

    fn generateBaseCastMethod(self: *Generator, class: Class, main_parent: ?*Class) !void {
        if (class.parents.len == 0) return;

        try self.print(
            "pub inline fn as(self: anytype, comptime T: type) _internal.ClassAsResult(@TypeOf(self), {s}, T) {{",
            .{class.name},
        );

        try self.print("const R = _internal.ClassAsResult(@TypeOf(self), {s}, T);", .{class.name});

        try self.print("return switch (T) {{", .{});

        for (class.parents) |parent| {
            if (parent == main_parent) {
                try self.print("{s} => @ptrCast(R, self),", .{parent.name});
            } else {
                try self.print("{s} => @ptrCast(R, &self.data._offset_to_{s}),", .{ parent.name, parent.name });
            }
        }

        try self.print("else => @compileError(\"Cannot convert {s} to non-parent type \" ++ @typeName(T)),", .{class.name});
        try self.print("}};", .{});
        try self.print("}}", .{});
    }
};

const ClassConverter = struct {
    allocator: std.mem.Allocator,
    inputs: []const RawClass,
    outputs: []Class,
    states: []State,

    const State = enum {
        not_started,
        in_conversion,
        done,
    };

    fn init(allocator: std.mem.Allocator, inputs: []RawClass) !ClassConverter {
        const outputs = try allocator.alloc(Class, inputs.len);
        const states = try allocator.alloc(State, inputs.len);

        std.mem.set(State, states, .not_started);

        return ClassConverter{
            .allocator = allocator,
            .inputs = inputs,
            .outputs = outputs,
            .states = states,
        };
    }

    fn getConverted(self: ClassConverter, name: []const u8) !*Class {
        for (self.inputs) |raw, i| {
            if (std.mem.eql(u8, raw.name, name)) {
                switch (self.states[i]) {
                    .not_started => try self.convert(@intCast(u32, i)),
                    .in_conversion => return error.RecursiveBaseClass,
                    .done => {},
                }
                return &self.outputs[i];
            }
        }
        return error.NoSuchClass;
    }

    const ConvertError = error{
        NoSuchClass,
        RecursiveBaseClass,
        OutOfMemory,
    };

    fn convert(self: ClassConverter, idx: u32) ConvertError!void {
        self.states[idx] = .in_conversion;

        const raw = self.inputs[idx];

        // TODO: there are some extra requirements here that aren't handled
        var standard_layout: bool = raw.vmethods.len == 0 and !raw.force_non_standard_layout;

        var first_vtable: ?u32 = null;
        var has_fields: bool = raw.fields.len != 0;
        var parents = try self.allocator.alloc(*Class, raw.parents.len);
        for (raw.parents) |name, i| {
            parents[i] = try self.getConverted(name);
            if (parents[i].vtable != .none and first_vtable == null) first_vtable = @intCast(u32, i);
            if (!parents[i].is_standard_layout) standard_layout = false; // non-standard-layout base
            if (parents[i].fields.len != 0) {
                if (!has_fields) {
                    has_fields = true;
                } else {
                    standard_layout = false; // multiple classes with fields involved
                }
            }
        }

        self.outputs[idx] = .{
            .name = raw.name,
            .parents = parents,
            .fields = raw.fields,
            .vmethods = raw.vmethods,
            .is_standard_layout = standard_layout,
            .vtable = if (first_vtable) |i| .{ .inherited = i } else if (raw.vmethods.len > 0) .new else .none,
        };

        self.states[idx] = .done;
    }

    fn run(self: ClassConverter) !void {
        for (self.states) |state, i| {
            switch (state) {
                .not_started => try self.convert(@intCast(u32, i)),
                .in_conversion => unreachable,
                .done => {},
            }
        }
    }
};

pub const ClassGenerator = struct {
    allocator: std.mem.Allocator,
    raw_classes: std.ArrayList(RawClass),
    abi: Abi,

    pub const Abi = enum {
        msvc,
        itanium,
    };

    pub fn init(allocator: std.mem.Allocator, abi: Abi) ClassGenerator {
        return .{
            .allocator = allocator,
            .raw_classes = std.ArrayList(RawClass).init(allocator),
            .abi = abi,
        };
    }

    pub fn addClassFile(self: *ClassGenerator, dir: std.fs.Dir, sub_name: []const u8) !void {
        var f = try dir.openFile(sub_name, .{});
        defer f.close();

        var br = std.io.bufferedReader(f.reader());

        try self.raw_classes.append(try parseClassFile(self.allocator, br.reader()));
    }

    pub fn finish(self: *ClassGenerator) ![]const u8 {
        const classes = blk: {
            var conv = try ClassConverter.init(self.allocator, self.raw_classes.items);
            try conv.run();
            break :blk conv.outputs;
        };

        var generator: Generator = .{
            .allocator = self.allocator,
            .buf = std.ArrayList(u8).init(self.allocator),
            .abi = self.abi,
        };

        try generator.begin();

        for (classes) |class| {
            try generator.generateClass(class);
        }

        const source = try generator.buf.toOwnedSliceSentinel(0);
        var tree = try std.zig.parse(self.allocator, source);
        defer tree.deinit(self.allocator);

        std.debug.assert(tree.errors.len == 0);

        return tree.render(self.allocator);
    }
};
