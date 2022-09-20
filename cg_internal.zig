const std = @import("std");

// This is not part of the build.zig code. Instead, it's included in the generated code
// as an internal package in order to provide the utility functions below.

pub fn PadStruct(comptime S: type, comptime pad_field: []const u8) type {
    std.debug.assert(std.meta.trait.is(.Struct)(S));
    std.debug.assert(std.meta.trait.isExtern(S));

    const fields = std.meta.fields(S);
    if (fields.len == 0) return S;

    const last = fields[fields.len - 1];
    const real_size = @offsetOf(S, last.name) + @sizeOf(last.field_type);
    const size = @sizeOf(S);

    const pad = size - real_size;

    comptime var info = @typeInfo(S);
    info.Struct.fields = info.Struct.fields ++ &[1]std.builtin.Type.StructField{.{
        .name = pad_field,
        .field_type = [pad]u8,
        .default_value = &@as([pad]u8, undefined),
        .is_comptime = false,
        .alignment = 0,
    }};
    return @Type(info);
}

pub fn ConcatStructs(comptime types: []const type) type {
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    for (types) |T| {
        std.debug.assert(std.meta.trait.is(.Struct)(T));
        std.debug.assert(std.meta.trait.isExtern(T));
        fields = fields ++ std.meta.fields(T);
    }
    return @Type(.{ .Struct = .{
        .layout = .Extern,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn ClassAsResult(comptime Ptr: type, comptime Child: type, comptime Base: type) type {
    std.debug.assert(std.meta.trait.isPtrTo(Child)(Ptr));
    const ptr = @typeInfo(Ptr).Pointer;
    return @Type(.{ .Pointer = .{
        .size = .One,
        .is_const = ptr.is_const,
        .is_volatile = ptr.is_volatile,
        .alignment = 0,
        .address_space = ptr.address_space,
        .child = Base,
        .is_allowzero = ptr.is_allowzero,
        .sentinel = null,
    } });
}
