const std = @import("std");
const net = std.net;
const http = std.http;
const Request = http.Server.Request;
const Allocator = std.mem.Allocator;

const Self = @This();
const OnRequest = *const fn (*Request) anyerror!void;
const OnError = *const fn (anyerror) void;

server: net.Server,
read_buffer: []u8,
write_buffer: []u8,
onRequest: OnRequest,
onError: OnError,

pub fn init(arena: Allocator, name: []const u8, port: u16, onRequest: OnRequest, onError: OnError) !Self {
    const addr = try net.Address.parseIp(name, port);
    const server = try addr.listen(.{
        .reuse_address = true,
    });
    const read_buffer = try arena.alloc(u8, 16384);
    const write_buffer = try arena.alloc(u8, 16384);
    return .{
        .server = server,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .onRequest = onRequest,
        .onError = onError,
    };
}
pub fn deinit(self: *Self, arena: Allocator) void {
    arena.free(self.read_buffer);
    arena.free(self.write_buffer);
    self.server.deinit();
}

pub fn address(self: *Self) *net.Address {
    return &self.server.listen_address;
}
pub fn url(self: *Self, arena: Allocator) ![]u8 {
    var host: std.ArrayList(u8) = .empty;
    defer host.deinit(arena);
    try host.print(arena, "http://{f}/", .{self.address()});
    return try host.toOwnedSlice(arena);
}

pub fn serve(self: *Self) void {
    accept: while (true) {
        const connection = self.server.accept() catch |err| {
            self.onError(err);
            continue :accept;
        };
        self.handleConnection(&connection) catch |err| {
            self.onError(err);
            continue :accept;
        };
    }
}

pub fn handleConnection(self: *Self, connection: *const net.Server.Connection) anyerror!void {
    const stream = &connection.stream;
    defer stream.close();
    var reader = stream.reader(self.read_buffer);
    var writer = stream.writer(self.write_buffer);
    var server = http.Server.init(reader.interface(), &writer.interface);
    while (server.reader.state == .ready) {
        var request = try server.receiveHead();
        try self.onRequest(&request);
    }
}
