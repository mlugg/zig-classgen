const std = @import("std");

pub const ZigType = union(enum) {
    named: []const u8,
    optional: struct {
        child: *ZigType,
    },
    func: struct {
        method: bool,
        args: []ZigType,
        variadic: bool,
        ret: *ZigType,
    },
    ptr: struct {
        ptr_type: union(enum) {
            single,
            many: struct { sentinel: ?[]const u8 },
        },
        is_const: bool,
        child: *ZigType,
    },
    array: struct {
        len: usize,
        child: *ZigType,
    },

    pub fn equals(a: ZigType, b: ZigType) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        switch (a) {
            .named => |name| {
                return std.mem.eql(u8, name, b.named);
            },

            .optional => |opt| {
                return opt.child.equals(b.optional.child.*);
            },

            .func => |func| {
                if (func.method != b.func.method) return false;
                if (func.variadic != b.func.variadic) return false;
                for (func.args) |arg, i| {
                    if (!arg.equals(b.func.args[i])) return false;
                }
                if (!func.ret.equals(b.func.ret.*)) return false;
                return true;
            },

            .ptr => |ptr| {
                switch (ptr.ptr_type) {
                    .single => {
                        if (b.ptr.ptr_type != .single) return false;
                    },
                    .many => |many| {
                        if (b.ptr.ptr_type != .many) return false;
                        if (many.sentinel) |sentinel| {
                            if (b.ptr.ptr_type.many.sentinel == null) return false;
                            if (!std.mem.eql(u8, sentinel, b.ptr.ptr_type.many.sentinel.?)) return false;
                        } else {
                            if (b.ptr.ptr_type.many.sentinel != null) return false;
                        }
                    },
                }
                if (ptr.is_const != b.ptr.is_const) return false;
                if (!ptr.child.equals(b.ptr.child.*)) return false;
                return true;
            },

            .array => |array| {
                if (array.len != b.array.len) return false;
                if (!array.child.equals(b.array.child.*)) return false;
                return true;
            },
        }
    }

    pub fn format(value: ZigType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (value) {
            .named => |name| try writer.writeAll(name),

            .optional => |opt| try writer.print("?{}", .{opt.child}),

            .func => |func| {
                try writer.writeAll("fn (");
                for (func.args) |arg, i| {
                    if (i == func.args.len - 1) {
                        try writer.print("{}", .{arg});
                    } else {
                        try writer.print("{},", .{arg});
                    }
                }
                if (func.variadic) try writer.writeAll(",...");
                try writer.print(") callconv({s}) {}", .{ if (func.method) @as([]const u8, "_Method") else @as([]const u8, ".C"), func.ret.* }); // TODO: variadic callconv
            },

            .ptr => |ptr| {
                switch (ptr.ptr_type) {
                    .single => try writer.writeAll("*"),
                    .many => |many| if (many.sentinel) |sentinel| {
                        try writer.print("[*:{s}]", .{sentinel});
                    } else {
                        try writer.writeAll("[*]");
                    },
                }
                if (ptr.is_const) try writer.writeAll("const ");
                try writer.print("{}", .{ptr.child.*});
            },

            .array => |array| {
                try writer.print("[{}]{}", .{ array.len, array.child.* });
            },
        }
    }
};

pub const VirtualMethod = struct {
    zig_name: []const u8,
    dispatch_group: []const u8,
    args: []ZigType,
    variadic: bool,
    ret: ZigType,
    zig_type: ZigType,

    pub fn equals(a: VirtualMethod, b: VirtualMethod) bool {
        if (!std.mem.eql(u8, a.dispatch_group, b.dispatch_group)) return false;
        if (a.args.len != b.args.len) return false;
        for (a.args) |arg, i| {
            if (!arg.equals(b.args[i])) return false;
        }
        if (!a.ret.equals(b.ret)) return false;
        return true;
    }
};

pub const Field = struct {
    zig_name: []const u8,
    zig_type: ZigType,
};

pub const RawClass = struct {
    name: []const u8,
    parents: [][]const u8,
    force_non_standard_layout: bool,
    fields: []Field,
    vmethods: []VirtualMethod,
};

pub const Class = struct {
    name: []const u8,
    parents: []*Class,
    fields: []Field,
    vmethods: []VirtualMethod,

    is_standard_layout: bool,
    vtable: union(enum) {
        none,
        new,
        inherited: u32, // parent idx
    },

    pub fn hasDirectMethod(self: Class, method: VirtualMethod) bool {
        for (self.vmethods) |m| {
            if (m.equals(method)) return true;
        }
        return false;
    }

    pub fn hasMainMethod(self: Class, method: VirtualMethod) bool {
        if (self.hasDirectMethod(method)) return true;

        switch (self.vtable) {
            .inherited => |i| if (self.parents[i].hasMainMethod(method)) return true,
            else => {},
        }

        return false;
    }

    pub fn hasAnyMethod(self: Class, method: VirtualMethod) bool {
        if (self.hasDirectMethod(method)) return true;

        for (self.parents) |p| {
            if (p.hasAnyMethod(method)) return true;
        }

        return false;
    }
};
