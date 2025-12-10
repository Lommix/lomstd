const std = @import("std");

pub fn binarySerialize(comptime T: type, val: T, w: *std.Io.Writer) !void {
    const Info = @typeInfo(T);

    switch (Info) {
        .void => {},
        .int => try w.writeInt(T, val, .little),
        .bool => try w.writeByte(if (val) 1 else 0),
        .float => {
            const bytes: [4]u8 = @bitCast(val);
            try w.writeAll(&bytes);
        },
        .@"enum" => |e| {
            if (e.fields.len == 0) return;

            const i: u32 = @intFromEnum(val);
            try w.writeInt(u32, i, .little);
        },
        .@"union" => |un| {
            const tag = std.meta.activeTag(val);
            const tag_int = @intFromEnum(tag);
            try w.writeByte(tag_int);
            inline for (un.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(tag))) {
                    if (field.type != void) {
                        try binarySerialize(field.type, @field(val, field.name), w);
                    }
                }
            }
        },
        .array => |arr| {
            for (val) |el| try binarySerialize(arr.child, el, w);
        },
        .optional => |opt| {
            var byte: u8 = 0;
            if (val != null) byte = 1;
            try w.writeByte(byte);

            if (val) |inner| {
                try binarySerialize(opt.child, inner, w);
            } else {
                const empty: [@sizeOf(opt.child)]u8 = @splat(0);
                try w.writeAll(&empty);
            }
        },
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    try binarySerialize(u32, @intCast(val.len), w);
                    for (val) |el| try binarySerialize(ptr.child, el, w);
                },
                .one => {
                    try binarySerialize(ptr.child, val.*, w);
                },
                else => {
                    return error.UnsupportedPointer;
                },
            }
        },
        .@"struct" => |stru| {
            switch (stru.layout) {
                .auto => {
                    inline for (stru.fields) |field| {
                        try binarySerialize(field.type, @field(val, field.name), w);
                    }
                },
                else => try w.writeAll(std.mem.asBytes(&val)),
            }
        },
        else => {
            return error.UnsupportedType;
        },
    }
}

pub fn binaryDeserialize(comptime T: type, gpa: std.mem.Allocator, reader: *std.Io.Reader) !T {
    const Info = @typeInfo(T);
    switch (Info) {
        .void => return {},
        .int => {
            return try reader.takeInt(T, .little);
        },
        .bool => {
            const b = try reader.takeByte();
            return b > 0;
        },
        .float => {
            const bytes = try reader.take(4);
            var val: f32 = 0;
            const val_bytes: []u8 = std.mem.asBytes(&val);
            @memcpy(val_bytes[0..4], bytes);
            return val;
        },
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    const size = try binaryDeserialize(u32, gpa, reader);
                    const slice = try gpa.alloc(ptr.child, @intCast(size));
                    for (0..size) |i| slice[i] = try binaryDeserialize(ptr.child, gpa, reader);
                    return slice;
                },
                .one => {
                    const val = try binaryDeserialize(ptr.child, gpa, reader);
                    const p = try gpa.create(ptr.child);
                    p.* = val;
                    return p;
                },
                else => {
                    return error.UnsupportedPointer;
                },
            }
        },
        .@"enum" => |e| {
            if (e.fields.len == 0) return undefined;

            const i = try reader.takeInt(u32, .little);
            return @enumFromInt(i);
        },
        .@"union" => |un| {
            const tag_byte = try reader.takeByte();

            inline for (un.fields, 0..) |field, tag_idx| {
                if (tag_byte == tag_idx) {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        const field_val = try binaryDeserialize(field.type, gpa, reader);
                        return @unionInit(T, field.name, field_val);
                    }
                }
            }

            return error.InvalidUnionTag;
        },
        .array => |arr| {
            @setEvalBranchQuota(3200);
            var a: [arr.len]arr.child = undefined;
            inline for (0..arr.len) |i| {
                a[i] = try binaryDeserialize(arr.child, gpa, reader);
            }
            return a;
        },
        .optional => |opt| {
            const v = try reader.takeByte();
            if (v > 0) {
                return try binaryDeserialize(opt.child, gpa, reader);
            } else {
                try reader.discardAll(@sizeOf(opt.child));
            }
            return null;
        },
        .@"struct" => |obj| {
            var val: T = undefined;
            switch (obj.layout) {
                .auto => {
                    inline for (obj.fields) |field| {
                        @field(val, field.name) = try binaryDeserialize(field.type, gpa, reader);
                    }
                },
                else => {
                    const bytes = try reader.take(@sizeOf(T));
                    @memcpy(std.mem.asBytes(&val), bytes);
                },
            }

            return val;
        },
        else => return error.UnsupportedType,
    }
}
