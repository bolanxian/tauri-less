const zip = @This();
const std = @import("std");
const ft = @import("file-time.zig");
const mem = std.mem;
const File = std.fs.File;
const Io = std.Io;
const Crc32 = std.hash.Crc32;

pub const Version = enum(u16) {
    pub const default: @This() = .oldest;
    oldest = 0xA,
    hasDeflateOrCrypto = 0x14,
    _,
};
pub const BitFlag = packed struct(u16) {
    pub const default: @This() = .{ .crypto = false };
    crypto: bool,
    _: u15 = 0,
};
pub const CompressMethod = enum(u16) {
    pub const default: @This() = .store;
    store = 0,
    deflate = 8,
    _,
};
pub const Date = packed struct(u32) {
    double_seconds: u5 = 0,
    minutes: u6 = 0,
    hours: u5 = 0,
    date: u5 = 1,
    month: u4 = 1,
    year: u7 = 0,
    pub fn fromSystemTime(systemTime: *const ft.SYSTEMTIME) Date {
        return .{
            .year = @intCast(systemTime.wYear - 1980),
            .month = @intCast(systemTime.wMonth),
            .date = @intCast(systemTime.wDay),
            .hours = @intCast(systemTime.wHour),
            .minutes = @intCast(systemTime.wMinute),
            .double_seconds = @intCast(@divFloor(systemTime.wSecond, 2)),
        };
    }
    pub fn fromHandle(hFile: ft.HANDLE) !Date {
        var time: ft.FILETIME = undefined;
        var localTime: ft.FILETIME = undefined;
        var systemTime: ft.SYSTEMTIME = undefined;
        try ft.GetFileTime(hFile, null, null, &time);
        try ft.FileTimeToLocalFileTime(&time, &localTime);
        try ft.FileTimeToSystemTime(&localTime, &systemTime);
        return .fromSystemTime(&systemTime);
    }
    pub fn fromFile(file: File) !Date {
        return .fromHandle(file.handle);
    }
};

pub const LocalFileHeader = packed struct(u240) {
    pub const MAGIC = 0x04034b50;
    magic: u32 = MAGIC,
    version: Version = .default,
    bit_flag: BitFlag = .default,
    compress_method: CompressMethod = .default,
    date: Date = .{},
    crc32: u32,
    compress_size: u32,
    size: u32,
    name_len: u16,
    extra_len: u16 = 0,
};
pub const CentralDirectoryHeader = packed struct(u368) {
    pub const MAGIC = 0x02014b50;
    magic: u32 = MAGIC,
    compress_version: Version = .default,
    version: Version = .default,
    bit_flag: BitFlag = .default,
    compress_method: CompressMethod = .default,
    date: Date = .{},
    crc32: u32,
    compress_size: u32,
    size: u32,
    name_len: u16,
    extra_len: u16 = 0,
    comment_len: u16 = 0,
    _12: u16 = 0,
    _13: u16 = 0,
    _14: u32 = 0,
    offset: u32,
};
pub const EndOfCentralDirectory = packed struct(u176) {
    pub const MAGIC = 0x06054b50;
    magic: u32 = MAGIC,
    _1: u16 = 0,
    _2: u16 = 0,
    central_count: u16,
    entry_count: u16,
    size: u32,
    offset: u32,
    comment_len: u16 = 0,
};

pub fn Int(comptime T: type) type {
    return @typeInfo(T).@"struct".backing_integer.?;
}
pub fn sizeOf(comptime T: type) comptime_int {
    return @divExact(@typeInfo(Int(T)).int.bits, 8);
}
pub fn Array(comptime T: type) type {
    return [sizeOf(T)]u8;
}

pub inline fn pack(self: anytype) Array(@TypeOf(self)) {
    var data: Array(@TypeOf(self)) = undefined;
    packTo(&data, self);
    return data;
}
pub inline fn packTo(data: []u8, self: anytype) void {
    const buffer: *Array(@TypeOf(self)) = data[0..sizeOf(@TypeOf(self))];
    mem.writeInt(Int(@TypeOf(self)), buffer, @bitCast(self), .little);
}
pub inline fn check(self: anytype) error{InvalidMagicNumber}!@TypeOf(self) {
    try if (self.magic != @TypeOf(self).MAGIC)
        error.InvalidMagicNumber;
    return self;
}
pub inline fn unpack(comptime T: type, data: []const u8) error{InvalidMagicNumber}!T {
    const self: T = @bitCast(mem.readInt(Int(T), data[0..sizeOf(T)], .little));
    return check(self);
}
test {
    inline for (.{ LocalFileHeader, CentralDirectoryHeader, EndOfCentralDirectory } ** 256) |T| {
        @setEvalBranchQuota(256 * 1024);
        var buffer: Array(T) = undefined;
        try std.posix.getrandom(&buffer);
        mem.writeInt(u32, buffer[0..4], T.MAGIC, .little);
        const unpacked = try unpack(T, &buffer);
        const @"packed" = pack(unpacked);
        std.debug.assert(unpacked == try unpack(T, &pack(unpacked)));
        std.debug.assert(mem.eql(u8, &@"packed", &buffer));
    }
}

pub const Writer = struct {
    const Self = @This();
    pub const Options = struct {
        version: Version = .default,
        bit_flag: BitFlag = .default,
        compress_method: CompressMethod = .default,
    };
    arena: mem.Allocator,
    options: Options,
    writer: *Io.Writer,
    header: Io.Writer.Allocating,
    entryCount: u16,
    pos: u32,
    pub fn init(arena: mem.Allocator, writer: *Io.Writer, options: Options) Self {
        return .{
            .arena = arena,
            .options = options,
            .writer = writer,
            .header = .init(arena),
            .entryCount = 0,
            .pos = 0,
        };
    }
    pub fn writeRaw(self: *Self, data: []const u8) !void {
        try self.writer.writeAll(data);
        self.pos += @intCast(data.len);
    }
    pub fn writeCustom(self: *Self, name: []const u8, data: []const u8, header: *LocalFileHeader) Error!void {
        header.name_len = @intCast(name.len);
        header.compress_size = @intCast(data.len);
        const pos = self.pos;
        try self.writer.writeStruct(header.*, .little);
        self.pos += sizeOf(LocalFileHeader);
        try self.writer.writeAll(name);
        self.pos += @intCast(name.len);
        try self.writer.writeAll(data);
        self.pos += @intCast(data.len);
        try self.header.writer.writeStruct(CentralDirectoryHeader{
            .compress_version = header.version,
            .version = header.version,
            .bit_flag = header.bit_flag,
            .compress_method = header.compress_method,
            .date = header.date,
            .crc32 = header.crc32,
            .compress_size = header.compress_size,
            .size = header.size,
            .name_len = header.name_len,
            .offset = pos,
        }, .little);
        try self.header.writer.writeAll(name);
        self.entryCount += 1;
    }
    pub fn write(self: *Self, name: []const u8, data: []const u8, date: Date) Error!void {
        const options = &self.options;
        const crc32: u32 = std.hash.Crc32.hash(data);
        var header: LocalFileHeader = .{
            .version = options.version,
            .bit_flag = options.bit_flag,
            .compress_method = options.compress_method,
            .date = date,
            .crc32 = crc32,
            .compress_size = 0,
            .size = @intCast(data.len),
            .name_len = 0,
        };
        try self.writeCustom(name, data, &header);
    }
    pub fn end(self: *Self) Error!void {
        const header = try self.header.toOwnedSlice();
        defer self.arena.free(header);
        try self.writer.writeAll(header);
        try self.writer.writeStruct(EndOfCentralDirectory{
            .central_count = self.entryCount,
            .entry_count = self.entryCount,
            .size = @intCast(header.len),
            .offset = self.pos,
        }, .little);
        try self.writer.flush();
    }
    pub fn deinit(self: *Self) void {
        self.header.deinit();
    }
    pub const Error = mem.Allocator.Error || Io.Writer.Error;
};

pub const Reader = struct {
    const Self = @This();
    file: File,
    header: Io.Reader,
    i: u16,
    entry_count: u16,
    pub fn init(arena: mem.Allocator, file: File) Error!Self {
        const eocd = do: {
            const Eocd = EndOfCentralDirectory;
            var buffer: Array(Eocd) = undefined;
            var reader = file.reader(&buffer);
            const size = reader.getSize() catch return File.Reader.SeekError.Unexpected;
            try reader.seekTo(size - sizeOf(Eocd));
            break :do try check(try reader.interface.takeStruct(Eocd, .little));
        };
        var reader = file.reader(&.{});
        try reader.seekTo(eocd.offset);
        const header = try reader.interface.readAlloc(arena, eocd.size);
        errdefer arena.free(header);

        return .{
            .file = file,
            .header = .fixed(header),
            .i = 0,
            .entry_count = eocd.entry_count,
        };
    }
    pub fn next(self: *Self) ?Entry {
        return self.nextInner() catch return null;
    }
    fn nextInner(self: *Self) Error!?Entry {
        if (self.i < self.entry_count) {
            self.i += 1;
            const Central = CentralDirectoryHeader;
            const central = try check(try self.header.takeStruct(Central, .little));
            const name = try self.header.take(central.name_len);
            self.header.toss(central.extra_len + central.comment_len);
            return .{
                .file = self.file,
                .name = name,
                .central = central,
            };
        }
        return null;
    }
    pub fn deinit(self: *const Self, arena: mem.Allocator) void {
        arena.free(self.header.buffer);
    }
    pub const Entry = struct {
        const Local = LocalFileHeader;

        file: File,
        name: []const u8,
        central: CentralDirectoryHeader,

        pub fn readLocalHeader(self: *const Entry) Error!Local {
            const central = &self.central;
            var buffer: Array(Local) = undefined;
            var reader = self.file.reader(&buffer);
            try reader.seekTo(central.offset);
            const local = try check(try reader.interface.takeStruct(Local, .little));
            return local;
        }
        pub fn checkHeader(self: *const Entry) Error!void {
            const local = try self.readLocalHeader();
            const central = &self.central;
            inline for (.{
                "version", "bit_flag", "compress_method",
                "date",    "crc32",    "compress_size",
                "size",    "name_len", "extra_len",
            }) |name| {
                const a = @field(local, name);
                const b = @field(central, name);
                if (a != b) return error.InvalidZipHeader;
            }
        }
        pub fn readUnchecked(self: *const Entry, arena: mem.Allocator) Error![]u8 {
            const central = &self.central;
            const data = try arena.alloc(u8, central.compress_size);
            errdefer arena.free(data);

            var reader = self.file.reader(&.{});
            try reader.seekTo(central.offset + sizeOf(LocalFileHeader) + central.name_len + central.extra_len);
            _ = try reader.interface.readSliceAll(data);
            return data;
        }
        pub fn read(self: *const Entry, arena: mem.Allocator) Error![]u8 {
            try self.checkHeader();
            return self.readUnchecked(arena);
        }
    };
    pub const Error = mem.Allocator.Error || File.Reader.SeekError || Io.Reader.Error || error{
        InvalidMagicNumber,
        InvalidZipHeader,
    };
};
