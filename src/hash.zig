/// super simple fast xor hash
pub fn hashStr(str: []const u8) u32 {
    var value: u32 = 2166136261;
    for (str) |c| value = (value ^ @as(u32, @intCast(c))) *% 16777619;
    return value;
}
