const std = @import("std");
const zap = @import("zap");

var Alloc =
    std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .thread_safe = true }){};

const FILE_PATH = "./linksaved";

pub fn makeResponse(filelines: *std.mem.TokenIterator(u8, std.mem.DelimiterType.sequence), alloc: *std.mem.Allocator) !std.ArrayList(u8).Slice {
    const header =
        \\<html>
        \\<body>
        \\ <h1>LinkSaver</h1>
        \\ <form action='/save' method="POST">
        \\    <input type="text" name="link" placeholder="ur link">
        \\    <input type="submit">
        \\ </form>
    ;

    const bottom =
        \\</body>
        \\</html>
    ;

    var linkarray = std.ArrayList(u8).init(alloc.*);

    var writer =
        linkarray.writer();

    try writer.writeAll(header);

    while (filelines.next()) |lines| {
        if (lines.len == 0) continue;
        try writer.print("<a href=\"{0s}\">{0s}</a> <br/>", .{lines});
    }

    try writer.writeAll(bottom);

    return try linkarray.toOwnedSlice();
}

pub fn readToEndFromFile(alloc: *std.mem.Allocator) ![]u8 {
    var read_file: std.fs.File = try std.fs.cwd().openFile(FILE_PATH, .{ .mode = std.fs.File.OpenMode.read_only });

    defer read_file.close();

    var file_content = try read_file.readToEndAlloc(alloc.*, std.math.maxInt(usize));

    return file_content;
}

pub fn homepage(req: zap.SimpleRequest) void {
    var alloc = Alloc.allocator();

    var file_content = readToEndFromFile(&alloc) catch |err| {
        std.log.err("{}", .{err});
        req.setStatus(zap.StatusCode.internal_server_error);
        return;
    };

    defer alloc.free(file_content);

    var filelines = std.mem.tokenizeSequence(u8, file_content, "\n");

    var res = makeResponse(&filelines, &alloc) catch |err| {
        std.debug.print("{}", .{err});
        return;
    };

    defer alloc.free(res);

    req.sendBody(res) catch return;
}

pub fn checkMethod(req: *const zap.SimpleRequest, cmp_method: []const u8) !void {
    if (req.*.method) |method| {
        if (!std.mem.eql(u8, method, cmp_method)) {
            req.setStatus(zap.StatusCode.method_not_allowed);
            try req.sendBody("Wrong method");
            return error.MethodNotAllowed;
        }
    }
}

pub fn parseBody(req: *const zap.SimpleRequest) !void {
    if (req.*.body != null) {
        try req.*.parseBody();
        return;
    }

    req.setStatus(zap.StatusCode.bad_request);
    try req.sendBody("No body");
}

pub fn addLinkToFile(link: *[]const u8, alloc: *std.mem.Allocator) !void {
    const file: std.fs.File = try std.fs.cwd().openFile(FILE_PATH, .{
        .mode = std.fs.File.OpenMode.read_write,
    });

    defer file.close();

    var file_array = std.ArrayList(u8).init(alloc.*);
    try file_array.writer().print("{s}\n", .{link.*});

    try file.reader().readAllArrayList(&file_array, std.math.maxInt(usize));

    var file_content = try file_array.toOwnedSlice();

    var create_file = try std.fs.cwd().createFile(FILE_PATH, std.fs.File.CreateFlags{});

    defer create_file.close();

    try create_file.writeAll(file_content);
}

pub fn savelink(req: zap.SimpleRequest) void {
    checkMethod(&req, "POST") catch |err| {
        std.log.err("{}", .{err});
        return;
    };

    parseBody(&req) catch |err| {
        std.log.err("{?}", .{err});
        return;
    };

    var alloc = Alloc.allocator();

    var hashbody = req.parametersToOwnedStrList(alloc, true) catch |err| {
        req.setStatus(zap.StatusCode.internal_server_error);
        req.sendError(err, 0);
        return;
    };

    defer hashbody.deinit();

    var link = req.getParamStr("link", alloc, false) catch |err| {
        std.debug.print("{}", .{err});

        req.setStatus(zap.StatusCode.bad_request);
        req.sendBody("No link") catch std.log.info("Error", .{});
        return;
    } orelse {
        req.setStatus(zap.StatusCode.bad_request);
        req.sendBody("No link") catch std.log.info("Error", .{});
        return;
    };

    defer link.deinit();

    addLinkToFile(&link.str, &alloc) catch |err| {
        std.log.err("{}", .{err});
        req.setStatus(zap.StatusCode.internal_server_error);
        return;
    };

    req.setStatus(zap.StatusCode.found);
    req.setHeader("location", "/") catch {};
}

pub fn dispatch_routes(req: zap.SimpleRequest) void {
    const routes = std.ComptimeStringMap(zap.SimpleHttpRequestFn, .{ .{ "/", homepage }, .{ "/save", savelink } });

    if (req.path) |path| {
        if (routes.get(path)) |handler| {
            return handler(req);
        }
    }

    req.sendBody("Unknown route") catch return;
}

pub fn main() !void {
    var createfile = try std.fs.cwd().createFile(FILE_PATH, std.fs.File.CreateFlags{ .truncate = false });
    createfile.close();

    var listener = zap.SimpleHttpListener.init(.{ .interface = "0.0.0.0", .port = 8080, .on_request = dispatch_routes, .log = true });

    try listener.listen();

    std.debug.print("\x1b[2K\rServe on http://{s}:{d}\n", .{ listener.settings.interface, listener.settings.port });

    zap.start(.{ .threads = 2, .workers = 2 });
}
