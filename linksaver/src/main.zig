const std = @import("std");
const zap = @import("zap");

var Alloc =
    std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .thread_safe = true }){};

const FILE_PATH = "./linksaved";

pub fn makeResponse(file_name: *[]const u8, filelines: *std.mem.TokenIterator(u8, std.mem.DelimiterType.sequence), alloc: *std.mem.Allocator) !std.ArrayList(u8).Slice {
    var linkarray = std.ArrayList(u8).init(alloc.*);

    var writer =
        linkarray.writer();

    try writer.print(
        \\<html>
        \\<body>
        \\ <h1>LinkSaver</h1>
        \\ <form action='/save/{s}' method="POST">
        \\    <input type="text" name="link" placeholder="ur link">
        \\    <input type="submit">
        \\ </form>
    , .{file_name.*});

    while (filelines.next()) |lines| {
        if (lines.len == 0) continue;
        try writer.print("<a href=\"{0s}\">{0s}</a> <br/>", .{lines});
    }

    try writer.writeAll(
        \\</body>
        \\</html>
    );

    return try linkarray.toOwnedSlice();
}

pub fn readToEndFromFile(file_name: *[]const u8, alloc: *std.mem.Allocator) ![]u8 {
    var read_file: std.fs.File = try std.fs.cwd().openFile(file_name.*, .{ .mode = std.fs.File.OpenMode.read_only });

    defer read_file.close();

    var file_content = try read_file.readToEndAlloc(alloc.*, std.math.maxInt(usize));

    return file_content;
}

pub fn createOrReadToEnd(file_name: *[]const u8, alloc: *std.mem.Allocator) ![]u8 {
    var tryfile =
        std.fs.cwd().openFile(file_name.*, .{});
    if (tryfile == std.fs.File.OpenError.FileNotFound) {
        var file = try std.fs.cwd().createFile(file_name.*, std.fs.File.CreateFlags{ .read = true });
        file.close();
    }

    return readToEndFromFile(file_name, alloc);
}

pub fn getFileName(req: *const zap.SimpleRequest, trim_path: []const u8) ?[]const u8 {
    var path = req.path orelse {
        return null;
    };

    if (std.mem.startsWith(u8, path, trim_path)) {
        path = path[trim_path.len..];
    }

    var token = std.mem.split(u8, path, "/");

    _ =
        token.next();

    var file = token.next() orelse {
        return null;
    };

    if (file.len == 0) {
        file = FILE_PATH;
    }

    return file;
}

pub fn homepage(req: zap.SimpleRequest) void {
    var alloc = Alloc.allocator();
    var file_name = getFileName(&req, "") orelse FILE_PATH;
    var file_content = createOrReadToEnd(&file_name, &alloc) catch |err| {
        std.log.err("Cannot open {s} : {}", .{ file_name, err });
        req.setStatus(zap.StatusCode.internal_server_error);
        return;
    };

    defer alloc.free(file_content);

    var filelines = std.mem.tokenizeSequence(u8, file_content, "\n");

    var res = makeResponse(&file_name, &filelines, &alloc) catch |err| {
        std.debug.print("{}", .{err});
        return;
    };

    defer alloc.free(res);

    req.sendBody(res) catch return;
}

pub fn parseBody(req: *const zap.SimpleRequest) !void {
    if (req.*.body != null) {
        try req.*.parseBody();
        return;
    }

    req.setStatus(zap.StatusCode.bad_request);
    try req.sendBody("No body");
}

pub fn addLinkToFile(file_name: *[]const u8, link: *[]const u8, alloc: *std.mem.Allocator) !void {
    const file: std.fs.File = try std.fs.cwd().openFile(file_name.*, .{
        .mode = std.fs.File.OpenMode.read_write,
    });

    defer file.close();

    var file_array = std.ArrayList(u8).init(alloc.*);
    try file_array.writer().print("{s}\n", .{link.*});

    try file.reader().readAllArrayList(&file_array, std.math.maxInt(usize));

    var file_content = try file_array.toOwnedSlice();

    var create_file = try std.fs.cwd().createFile(file_name.*, std.fs.File.CreateFlags{});

    defer create_file.close();

    try create_file.writeAll(file_content);
}

pub fn savelink(req: zap.SimpleRequest) !void {
    try parseBody(&req);

    var file_name = getFileName(&req, "/save") orelse FILE_PATH;

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

    addLinkToFile(&file_name, &link.str, &alloc) catch |err| {
        std.log.err("{}", .{err});
        req.setStatus(zap.StatusCode.internal_server_error);
        return;
    };

    req.setStatus(zap.StatusCode.found);

    var buffer = std.ArrayList(u8).init(alloc);

    try buffer.appendSlice("/");
    try buffer.appendSlice(file_name);

    try req.setHeader("location", try buffer.toOwnedSlice());
}

pub fn dispatch_routes(req: zap.SimpleRequest) void {
    if (req.path) |path| {
        _ = path;
        var method = req.method orelse {
            return;
        };

        if (std.mem.eql(u8, "GET", method) or std.mem.eql(u8, "get", method)) {
            return homepage(req);
        }

        if (std.mem.eql(u8, "POST", method) or std.mem.eql(u8, "post", method)) {
            return savelink(req) catch |err| {
                std.debug.print("Error: {}", .{err});
            };
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
