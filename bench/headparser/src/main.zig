const std = @import("std");
const HeadParser = std.http.HeadParser;

pub fn main() !void {
    const buffer: []const u8 = "GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\nAccept-Encoding: gzip,deflate,sdch\r\nAccept-Language: en-US,en;q=0.8\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\nCookie: name=wookie\r\n\r\n";

    var i: usize = 0;
    while (i < 1_000_000_0) : (i += 1) {
        var p: HeadParser = .{};

        _ = std.mem.doNotOptimizeAway(p.feed(buffer[0..])); // 430
    }
}
