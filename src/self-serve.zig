const std = @import("std");
const fs = std.fs;
const path = std.fs.path;
const mem = std.mem;
const net = std.net;
const http = std.http;
const Server = @import("server.zig");
const zip = @import("zip.zig");

const serverHeader: http.Header = .{ .name = "server", .value = "tauri-less" };
const defaultType = "application/octet-stream";
const typeList = [_]struct { []const u8, []const u8 }{
    .{ "css", "text/css" },
    .{ "html", "text/html" },
    .{ "js", "text/javascript" },
    .{ "json", "application/json" },
    .{ "txt", "text/plain" },
    .{ "svg", "image/svg+xml" },
    .{ "woff2", "font/woff2" },
    .{ "wasm", "application/wasm" },
};

var typeMap: std.StringHashMap([]const u8) = undefined;
var fileMap: HashMap = undefined;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    typeMap = .init(arena);
    defer typeMap.deinit();
    for (typeList) |kv| {
        try typeMap.put(kv.@"0", kv.@"1");
    }

    fileMap = .init(arena);
    defer fileMap.deinit();
    {
        const exe = try fs.openSelfExe(.{});
        defer exe.close();
        var reader = try zip.Reader.init(arena, exe);
        defer reader.deinit(arena);
        while (reader.next()) |entry| {
            const data = try entry.read(arena);
            defer arena.free(data);
            const crc32 = std.hash.Crc32.hash(data);
            if (crc32 != entry.central.crc32)
                std.log.warn("Invalid crc32: {s}", .{entry.name});
            try fileMap.put(entry.name, data);
        }
    }
    var server = try Server.init(arena, "127.0.0.1", 0, handleRequest, handleError);
    defer server.deinit(arena);
    const url = try server.url(arena);
    defer arena.free(url);
    std.debug.print("Listening on {s}\n", .{url});

    var child: std.process.Child = .init(&.{ "explorer", url }, arena);
    try child.spawn();
    server.serve();
    _ = try child.wait();
}

const HashMap = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
    inner: std.StringHashMap([]const u8),
    pub fn init(arena: mem.Allocator) Self {
        return .{
            .arena = .init(arena),
            .inner = .init(arena),
        };
    }
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const arena = self.arena.allocator();
        if (try self.inner.fetchPut(
            try arena.dupe(u8, key),
            try arena.dupe(u8, value),
        )) |kv| {
            arena.free(kv.value);
        }
    }
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.inner.get(key);
    }
    pub fn deinit(self: *Self) void {
        self.inner.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    test {
        var map = Self.init(std.testing.allocator);
        defer map.deinit();
        try map.put("a", "d");
        try map.put("b", "e");
        try map.put("c", "f");
        try std.testing.expectEqualSlices(u8, map.get("a").?, "d");
        try std.testing.expectEqualSlices(u8, map.get("b").?, "e");
        try std.testing.expectEqualSlices(u8, map.get("c").?, "f");
        try std.testing.expect(map.get("d") == null);
    }
};
test {
    _ = HashMap;
}

fn handleRequest(request: *http.Server.Request) !void {
    const target = request.head.target;
    const pathname, const search = if (mem.indexOf(u8, target, "?")) |index|
        .{ target[0..index], target[index + 1 ..] }
    else
        .{ target, "" };
    _ = search;

    if (!(pathname.len > 1)) {
        return request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                serverHeader,
                .{ .name = "location", .value = "index.html" },
            },
        });
    }
    if (fileMap.get(pathname[1..])) |data| {
        const ext = path.extension(pathname);
        const @"type" = (if (ext.len > 1) typeMap.get(ext[1..]) else null) orelse defaultType;

        return request.respond(data, .{
            .status = .ok,
            .extra_headers = &.{
                serverHeader,
                .{ .name = "content-type", .value = @"type" },
            },
        });
    }
    return request.respond("<h1>404 Not Found</h1>", .{
        .status = .not_found,
        .extra_headers = &.{
            serverHeader,
            .{ .name = "content-type", .value = "text/html" },
        },
    });
}

fn handleError(err: anyerror) void {
    switch (err) {
        error.HttpConnectionClosing => {},
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        },
    }
}
