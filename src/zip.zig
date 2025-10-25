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
    return @bitCast(mem.nativeToLittle(Int(@TypeOf(self)), @bitCast(self)));
}
pub inline fn packTo(data: []u8, self: anytype) void {
    data[0..sizeOf(@TypeOf(self))].* = pack(self);
}
pub inline fn unpack(comptime T: type, data: []const u8) !T {
    const inst: T = @bitCast(mem.littleToNative(Int(T), @bitCast(data[0..sizeOf(T)].*)));
    try if (inst.magic != T.MAGIC)
        error.InvalidMagicNumber;
    return inst;
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
        const crc32: u32 = do: {
            var crc32: std.hash.Crc32 = .init();
            crc32.update(data);
            break :do crc32.final();
        };
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
    header: []const u8,
    offset: usize = 0,
    pub fn init(arena: mem.Allocator, file: File) Error!Self {
        const eocd = do: {
            const T = EndOfCentralDirectory;
            try file.seekFromEnd(-sizeOf(T));
            var eocd: Array(T) = undefined;
            _ = try file.readAll(&eocd);
            break :do try unpack(T, &eocd);
        };
        try file.seekTo(eocd.offset);
        const header = try arena.alloc(u8, eocd.size);
        errdefer arena.free(header);
        _ = try file.readAll(header);

        return .{
            .file = file,
            .header = header,
        };
    }
    pub fn next(self: *Self) ?Entry {
        if (self.offset < self.header.len) {
            const central = unpack(CentralDirectoryHeader, self.header[self.offset..]) catch return null;
            self.offset += sizeOf(CentralDirectoryHeader);
            const name = self.header[self.offset..][0..central.name_len];
            const entry = Entry.init(self.file, central, name);
            self.offset += central.name_len + central.extra_len + central.comment_len;
            return entry;
        }
        return null;
    }
    pub fn deinit(self: *const Self, arena: mem.Allocator) void {
        arena.free(self.header);
    }
    pub const Entry = struct {
        file: File,
        central: CentralDirectoryHeader,
        name: []const u8,
        pub fn init(
            file: File,
            central: CentralDirectoryHeader,
            name: []const u8,
        ) Entry {
            return .{
                .file = file,
                .central = central,
                .name = name,
            };
        }
        pub fn read(self: *const Entry, arena: mem.Allocator) Error![]u8 {
            const central = &self.central;
            try self.file.seekTo(central.offset);
            var buffer: Array(LocalFileHeader) = undefined;
            _ = try self.file.readAll(&buffer);
            const header = try unpack(LocalFileHeader, &buffer);
            inline for (.{
                "version", "bit_flag", "compress_method",
                "date",    "crc32",    "compress_size",
                "size",    "name_len",
            }) |name| {
                const a = @field(header, name);
                const b = @field(central, name);
                if (a != b) return error.InvalidZipHeader;
            }
            const data = try arena.alloc(u8, central.compress_size);
            errdefer arena.free(data);
            try self.file.seekTo(central.offset + sizeOf(LocalFileHeader) + header.name_len + header.extra_len);
            _ = try self.file.readAll(data);
            return data;
        }
    };
    pub const Error = mem.Allocator.Error || File.ReadError || File.SeekError || error{
        InvalidMagicNumber,
        InvalidZipHeader,
    };
};
