const std = @import("std");
const mem = std.mem;
const net = std.net;
const fs = std.fs;
const path = std.fs.path;
const log = std.log.default;
const Server = @import("server.zig");
const zip = @import("zip.zig");
const selfServe = @embedFile("./deps/self-serve.exe");

fn help(arena: mem.Allocator, args: [][:0]u8) !noreturn {
    const arg0 = try path.relative(arena, ".", args[0]);
    defer arena.free(arg0);
    log.info("Usage : {s} <dir-path>", .{arg0});
    std.process.exit(1);
}

pub fn main() !void {
    _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);
    if (args.len != 2) try help(arena, args);

    const dirPath = args[1];
    const targetPath = do: {
        const cwdPath = try std.process.getCwdAlloc(arena);
        defer arena.free(cwdPath);
        var target: std.ArrayList(u8) = .fromOwnedSlice(try path.resolve(arena, &.{ cwdPath, dirPath }));
        defer target.deinit(arena);
        try target.appendSlice(arena, ".exe");
        break :do try target.toOwnedSlice(arena);
    };
    defer arena.free(targetPath);
    log.info("target: {s}", .{targetPath});

    const cwd = fs.cwd();
    var dir = try cwd.openDir(dirPath, .{ .iterate = true });
    defer dir.close();
    var iter = try dir.walk(arena);
    defer iter.deinit();
    var count: u32 = 0;

    const target = try cwd.createFile(targetPath, .{});
    defer target.close();
    var buffer: [8 * 1024 * 1024]u8 = undefined;
    var target_writer = target.writer(&buffer);
    var writer: zip.Writer = .init(arena, &target_writer.interface, .{});
    defer writer.deinit();
    try writer.writeRaw(selfServe);
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (mem.startsWith(u8, path.basename(entry.path), ".")) continue;
        count += 1;
        if (count > 128) return error.FileTooMuch;

        const entryPath = try mem.replaceOwned(u8, arena, entry.path, &.{path.sep_windows}, &.{path.sep_posix});
        defer arena.free(entryPath);
        log.info("file: {s}", .{entryPath});

        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(arena, 16 * 1024 * 1024);
        defer arena.free(data);
        try writer.write(entryPath, data, try .fromFile(file));
    }
    try writer.end();
}
