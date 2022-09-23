const std = @import("std");

const ZigType = @import("common.zig").ZigType;
const Field = @import("common.zig").Field;
const VirtualMethod = @import("common.zig").VirtualMethod;
const RawClass = @import("common.zig").RawClass;

const TypeParser = struct {
    const max_peek = 2;

    allocator: std.mem.Allocator,
    toks: std.zig.Tokenizer,
    peeked_buf: [max_peek]std.zig.Token = undefined,
    num_peeked: u32 = 0,

    fn peek(self: *TypeParser, idx: u32) std.zig.Token {
        std.debug.assert(idx < max_peek);

        while (self.num_peeked <= idx) {
            self.peeked_buf[self.num_peeked] = self.toks.next();
            self.num_peeked += 1;
        }

        return self.peeked_buf[idx];
    }

    fn next(self: *TypeParser) std.zig.Token {
        const tok = self.peek(0);
        std.mem.copy(std.zig.Token, &self.peeked_buf, self.peeked_buf[1..]);
        self.num_peeked -= 1;
        return tok;
    }

    fn parseAlloc(self: *TypeParser) !*ZigType {
        const ty = try self.allocator.create(ZigType);
        ty.* = try self.parse();
        return ty;
    }

    fn parse(self: *TypeParser) !ZigType {
        return switch (self.peek(0).tag) {
            .identifier => self.parseNamedType(),
            .l_bracket => self.parseArray(),
            .asterisk => self.parsePointer(),
            .question_mark => self.parseOptional(),
            .keyword_fn => self.parseFn(),
            else => error.BadToken,
        };
    }

    fn parseNamedType(self: *TypeParser) !ZigType {
        var name = std.ArrayList(u8).init(self.allocator);

        var tok = self.next();
        if (tok.tag != .identifier) return error.BadToken;
        try name.appendSlice(self.toks.buffer[tok.loc.start..tok.loc.end]);

        while (self.peek(0).tag == .period) {
            _ = self.next();
            tok = self.next();
            if (tok.tag != .identifier) return error.BadToken;
            try name.append('.');
            try name.appendSlice(self.toks.buffer[tok.loc.start..tok.loc.end]);
        }

        return ZigType{ .named = name.toOwnedSlice() };
    }

    fn parseArray(self: *TypeParser) !ZigType {
        if (self.peek(0).tag != .l_bracket) return error.BadToken;
        if (self.peek(1).tag == .asterisk) return self.parsePointer();

        _ = self.next();
        const tok = self.next();

        if (tok.tag != .integer_literal) return error.BadToken;

        const len = std.fmt.parseUnsigned(
            usize,
            self.toks.buffer[tok.loc.start..tok.loc.end],
            10,
        ) catch return error.BadToken;

        if (self.next().tag != .r_bracket) return error.BadToken;

        return ZigType{ .array = .{
            .len = len,
            .child = try self.parseAlloc(),
        } };
    }

    fn parsePointer(self: *TypeParser) !ZigType {
        var ty: ZigType = .{ .ptr = undefined };

        switch (self.next().tag) {
            .asterisk => ty.ptr.ptr_type = .single,
            .l_bracket => {
                if (self.next().tag != .asterisk) return error.BadToken;
                switch (self.next().tag) {
                    .colon => {
                        const sentinel = self.next();
                        ty.ptr.ptr_type = .{ .many = .{
                            .sentinel = self.toks.buffer[sentinel.loc.start..sentinel.loc.end],
                        } };
                        if (self.next().tag != .r_bracket) return error.BadToken;
                    },
                    .r_bracket => {
                        ty.ptr.ptr_type = .{ .many = .{ .sentinel = null } };
                    },
                    else => return error.BadToken,
                }
            },
            else => return error.BadToken,
        }

        if (self.peek(0).tag == .keyword_const) {
            _ = self.next();
            ty.ptr.is_const = true;
        } else {
            ty.ptr.is_const = false;
        }

        ty.ptr.child = try self.parseAlloc();

        return ty;
    }

    fn parseOptional(self: *TypeParser) !ZigType {
        if (self.next().tag != .question_mark) return error.BadToken;

        return ZigType{ .optional = .{
            .child = try self.parseAlloc(),
        } };
    }

    fn parseFn(self: *TypeParser) !ZigType {
        if (self.next().tag != .keyword_fn) return error.BadToken;
        if (self.next().tag != .l_paren) return error.BadToken;

        var args = std.ArrayList(ZigType).init(self.allocator);
        var variadic = false;

        while (self.peek(0).tag != .r_paren) {
            if (variadic) return error.BadToken;

            switch (self.peek(0).tag) {
                .ellipsis3 => {
                    _ = self.next();
                    variadic = true;
                },
                .identifier => {
                    // Might be a name or a type
                    if (self.peek(1).tag == .colon) {
                        _ = self.next();
                        _ = self.next();
                    }
                    try args.append(try self.parse());
                },
                else => try args.append(try self.parse()),
            }

            switch (self.peek(0).tag) {
                .comma => _ = self.next(),
                .r_paren => break,
                else => return error.BadToken,
            }
        }

        _ = self.next();

        return ZigType{ .func = .{
            .method = false,
            .args = args.toOwnedSlice(),
            .variadic = variadic,
            .ret = try self.parseAlloc(),
        } };
    }
};

fn parseType(allocator: std.mem.Allocator, str: [:0]const u8) !ZigType {
    var parser = TypeParser{
        .allocator = allocator,
        .toks = std.zig.Tokenizer.init(str),
    };

    const ty = parser.parse() catch |err| switch (err) {
        error.BadToken => return error.TypeParseError,
        else => |e| return e,
    };

    if (parser.next().tag != .eof) return error.TypeParseError;

    return ty;
}

fn ClassFileParser(comptime Reader: type) type {
    return struct {
        allocator: std.mem.Allocator,
        stream: std.io.PeekStream(.{ .Static = 1 }, Reader),
        peeked_line: ?Line = null,

        const Self = @This();

        const Line = union(enum) {
            name: []const u8,
            inherits: []const u8,
            non_standard_layout,
            fields,
            vmethods,
            skip: u32,
            destructor,
            decl: struct { name: []const u8, alt_name: ?[]const u8, ty: ZigType },
            eof,
        };

        fn nameValid(name: []const u8) bool {
            for (name) |c, i| {
                if (c >= 'a' and c <= 'z') continue;
                if (c >= 'A' and c <= 'Z') continue;
                if (c >= '0' and c <= '9' and i > 0) continue;
                if (c == '_') continue;
                return false;
            }
            return true;
        }

        fn consumeWhitespace(self: *Self) !void {
            while (true) {
                const c = self.stream.reader().readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };

                if (c == '\n') continue;
                if (c == ' ') continue;
                if (c == '#') {
                    try self.stream.reader().skipUntilDelimiterOrEof('\n');
                    continue;
                }

                self.stream.putBackByte(c) catch unreachable;
                break;
            }
        }

        fn readLine(self: *Self) !Line {
            try self.consumeWhitespace();

            const line = try self.stream.reader().readUntilDelimiterOrEofAlloc(self.allocator, '\n', std.math.maxInt(usize)) orelse return Line.eof;

            const directive = std.mem.sliceTo(line, ' ');
            const rem = std.mem.trim(u8, line[directive.len..], " ");

            if (std.mem.eql(u8, directive, "NAME")) {
                return Line{ .name = rem };
            } else if (std.mem.eql(u8, directive, "INHERITS")) {
                return Line{ .inherits = rem };
            } else if (std.mem.eql(u8, directive, "NON_STANDARD_LAYOUT")) {
                if (rem.len != 0) return error.NonStandardLayoutTrailingChars;
                return Line.non_standard_layout;
            } else if (std.mem.eql(u8, directive, "FIELDS")) {
                if (rem.len != 0) return error.FieldsTrailingChars;
                return Line.fields;
            } else if (std.mem.eql(u8, directive, "VMETHODS")) {
                if (rem.len != 0) return error.VmethodsTrailingChars;
                return Line.vmethods;
            } else if (std.mem.eql(u8, directive, "SKIP")) {
                return Line{
                    .skip = std.fmt.parseInt(u32, rem, 10) catch return error.BadSkipCount,
                };
            } else if (std.mem.eql(u8, directive, "DESTRUCTOR")) {
                if (rem.len != 0) return error.DestructorTrailingChars;
                return Line.destructor;
            }

            // Not a directive, must be a decl

            const idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadLine;
            const full_name = line[0..idx];

            const main_name = std.mem.sliceTo(full_name, '(');
            const alt_name = if (main_name.len == full_name.len) null else blk: {
                if (full_name[full_name.len - 1] != ')') {
                    return error.InvalidDeclName;
                }
                break :blk full_name[main_name.len + 1 .. full_name.len - 1];
            };

            if (!nameValid(main_name)) return error.InvalidDeclName;
            if (alt_name) |name| if (!nameValid(name)) return error.InvalidDeclName;

            const ty_str = try self.allocator.dupeZ(u8, line[idx + 1 ..]);
            const ty = try parseType(self.allocator, ty_str);

            return Line{ .decl = .{
                .name = main_name,
                .alt_name = alt_name,
                .ty = ty,
            } };
        }

        fn peekLine(self: *Self) !Line {
            if (self.peeked_line) |l| return l;

            const l = try self.readLine();
            self.peeked_line = l;
            return l;
        }

        fn nextLine(self: *Self) !Line {
            const l = try self.peekLine();
            self.peeked_line = null;
            return l;
        }

        const Preamble = struct {
            name: []const u8,
            parents: [][]const u8,
            force_non_standard_layout: bool,
        };

        fn parse(self: *Self) !RawClass {
            const preamble = try self.parsePreamble();

            const fields = if (.fields == try self.peekLine()) blk: {
                _ = self.nextLine() catch unreachable;
                break :blk try self.parseFields();
            } else @as([]Field, &.{});

            const vmethods = if (.vmethods == try self.peekLine()) blk: {
                _ = self.nextLine() catch unreachable;
                break :blk try self.parseVmethods(preamble.name);
            } else @as([]VirtualMethod, &.{});

            try self.consumeWhitespace();
            if (.eof != try self.peekLine()) return error.BadClassFile;

            return RawClass{
                .name = preamble.name,
                .parents = preamble.parents,
                .force_non_standard_layout = preamble.force_non_standard_layout,
                .fields = fields,
                .vmethods = vmethods,
            };
        }

        fn parsePreamble(self: *Self) !Preamble {
            const class_name = switch (try self.readLine()) {
                .name => |name| name,
                else => return error.NoClassName,
            };

            var parents = std.ArrayList([]const u8).init(self.allocator);
            var force_non_standard_layout: bool = false;

            while (true) {
                switch (try self.peekLine()) {
                    .inherits => |base| try parents.append(base),
                    .non_standard_layout => {
                        if (force_non_standard_layout) return error.DuplicateNonStandardLayoutLine;
                        force_non_standard_layout = true;
                    },
                    else => break,
                }
                _ = self.nextLine() catch unreachable;
            }

            return Preamble{
                .name = class_name,
                .parents = parents.toOwnedSlice(),
                .force_non_standard_layout = force_non_standard_layout,
            };
        }

        fn parseFields(self: *Self) ![]Field {
            var fields = std.ArrayList(Field).init(self.allocator);

            while (true) {
                switch (try self.peekLine()) {
                    .decl => |decl| {
                        _ = self.nextLine() catch unreachable;

                        if (decl.alt_name != null) return error.AltNameOnField;

                        try fields.append(.{
                            .zig_name = decl.name,
                            .zig_type = decl.ty,
                        });
                    },

                    else => break,
                }
            }

            return fields.toOwnedSlice();
        }

        fn createMethodType(self: *Self, class_name: []const u8, fn_ty: ZigType) !ZigType {
            const this_ty = try self.allocator.create(ZigType);
            this_ty.* = .{ .named = class_name };

            const args = try self.allocator.alloc(ZigType, fn_ty.func.args.len + 1);
            args[0] = .{
                .ptr = .{
                    .ptr_type = .single,
                    .is_const = false, // TODO: const methods
                    .child = this_ty,
                },
            };
            std.mem.copy(ZigType, args[1..], fn_ty.func.args);

            const method_ty = try self.allocator.create(ZigType);
            method_ty.* = .{ .func = .{
                .method = true,
                .args = args,
                .variadic = fn_ty.func.variadic,
                .ret = fn_ty.func.ret,
            } };

            return ZigType{ .ptr = .{
                .ptr_type = .single,
                .is_const = true,
                .child = method_ty,
            } };
        }

        fn parseVmethods(self: *Self, class_name: []const u8) ![]VirtualMethod {
            var methods = std.ArrayList(VirtualMethod).init(self.allocator);

            var generated_idx: u32 = 0;

            while (true) {
                switch (try self.peekLine()) {
                    .decl => |decl| {
                        _ = self.nextLine() catch unreachable;

                        if (decl.ty != .func) return error.NonFunctionMethod;

                        try methods.append(.{
                            .zig_name = decl.name,
                            .dispatch_group = decl.alt_name orelse decl.name,
                            .args = decl.ty.func.args,
                            .variadic = decl.ty.func.variadic,
                            .ret = decl.ty.func.ret.*,
                            .zig_type = try self.createMethodType(class_name, decl.ty),
                        });
                    },

                    .skip => |num_skip| {
                        _ = self.nextLine() catch unreachable;

                        const gen_to = generated_idx + num_skip;
                        while (generated_idx < gen_to) : (generated_idx += 1) {
                            const name = try std.fmt.allocPrint(self.allocator, "_gen_{s}_{}", .{ class_name, generated_idx });
                            try methods.append(.{
                                .zig_name = name,
                                .dispatch_group = name,
                                .args = &.{},
                                .variadic = false,
                                .ret = .{ .named = "void" },
                                .zig_type = .{ .named = "usize" },
                            });
                        }
                    },

                    .destructor => {
                        _ = self.nextLine() catch unreachable;

                        try methods.append(.{
                            .zig_name = "~",
                            .dispatch_group = "~",
                            .args = &.{},
                            .variadic = false,
                            .ret = .{ .named = "void" },
                            .zig_type = .{ .named = "usize" },
                        });
                    },

                    else => break,
                }
            }

            return methods.toOwnedSlice();
        }
    };
}

pub fn parseClassFile(allocator: std.mem.Allocator, reader: anytype) !RawClass {
    var parser: ClassFileParser(@TypeOf(reader)) = .{
        .allocator = allocator,
        .stream = std.io.peekStream(1, reader),
    };
    return parser.parse();
}
