const std = @import("std");
const zap = @import("zap");

var Alloc =
    std.heap.GeneralPurposeAllocator(.{ .verbose_log = false, .thread_safe = true }){};

const FILE_PATH = "./linksaved";

pub fn homepage(req: zap.SimpleRequest) void {
    var alloc = Alloc.allocator();

    var read_file: std.fs.File = std.fs.cwd().openFile(FILE_PATH, .{ .mode = std.fs.File.OpenMode.read_only }) catch {
        std.debug.print("Cannot open file", .{});
        return;
    };

    defer read_file.close();

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

    var file_content = read_file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch {
        std.log.err("Cannot read file", .{});
        return;
    };

    defer alloc.free(file_content);

    var filelines = std.mem.tokenizeSequence(u8, file_content, "\n");

    var linkarray = std.ArrayList(u8).init(alloc);
    defer linkarray.deinit();

    var writer =
        linkarray.writer();

    writer.writeAll(header) catch {
        return;
    };

    while (filelines.next()) |lines| {
        if (lines.len == 0) continue;
        writer.print("<a href=\"{0s}\">{0s}</a> <br/>", .{lines}) catch {};
    }

    writer.writeAll(bottom) catch {
        return;
    };

    var res = linkarray.toOwnedSlice() catch {
        return;
    };

    defer alloc.free(res);

    req.sendBody(res) catch return;
}

pub fn savelink(req: zap.SimpleRequest) void {
    if (req.method) |method| {
        if (!std.mem.eql(u8, method, "POST")) {
            req.setStatus(zap.StatusCode.method_not_allowed);
            req.sendBody("Wrong method") catch {};
            return;
        }
    }

    if (req.body == null) {
        req.setStatus(zap.StatusCode.bad_request);
        req.sendBody("No body !?") catch {
            std.log.err("Body is empty", .{});
        };
        return;
    }

    req.parseBody() catch |err| {
        std.log.err("{?}", .{err});

        req.setStatus(zap.StatusCode.bad_request);
        req.sendBody("Cannot parse body") catch |send_err| {
            std.log.err("{?}", .{send_err});
        };

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

    const file: std.fs.File = std.fs.cwd().openFile("./linksaved", .{
        .mode = std.fs.File.OpenMode.read_write,
    }) catch {
        return;
    };

    defer file.close();

    var file_array = std.ArrayList(u8).init(alloc);
    file_array.writer().print("{s}\n", .{link.str}) catch {
        return;
    };

    file.reader().readAllArrayList(&file_array, std.math.maxInt(usize)) catch {
        return;
    };

    var file_content = file_array.toOwnedSlice() catch {
        return;
    };

    var create_file = std.fs.cwd().createFile(FILE_PATH, std.fs.File.CreateFlags{}) catch |err| {
        std.debug.panic("error : {any}", .{err});
        return;
    };

    defer create_file.close();

    create_file.writeAll(file_content) catch |write_err| {
        std.log.err("Error {any}", .{write_err});
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
    var createfile = std.fs.cwd().createFile(FILE_PATH, std.fs.File.CreateFlags{ .truncate = false }) catch |ee| {
        std.debug.panic("error : {any}", .{ee});
        return null;
    };

    createfile.close();
    var listener = zap.SimpleHttpListener.init(.{ .port = 8080, .on_request = dispatch_routes, .log = true });

    try listener.listen();

    std.debug.print("\x1b[2K\rServe on http://{s}:{d}\n", .{ listener.settings.interface, listener.settings.port });

    zap.start(.{ .threads = 8, .workers = 8 });
}
