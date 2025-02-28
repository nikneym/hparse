//! zero allocation, stateless and streaming HTTP parser module.
//! By streaming, it can parse partially received HTTP requests.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

/// Block size of the CPU.
const block_size = @sizeOf(usize);

// If suggested vector length is null, prefer not to use vectors!
const use_vectors = blk: {
    const recommended = std.simd.suggestVectorLength(u8);
    break :blk if (recommended == null) false else true;
};

/// This is what we use for vector sizes in vectored operations.
/// If `use_vectors` is false, this gives the default block size for the CPU.
const vec_size = blk: {
    if (std.simd.suggestVectorLength(u8)) |recommended| {
        // In the future, we can look for ways to utilize 512-bit (AVX-512) or even larger registers.
        break :blk if (recommended >= 64) 32 else recommended;
    } else {
        // If vectors are not recommended, we prefer the default block size.
        break :blk block_size;
    }
};

/// `vec_size` as unsigned integer type.
const VectorInt = std.meta.Int(.unsigned, vec_size);

/// HTTP methods
pub const Method = enum(u8) {
    unknown,
    get,
    post,
    head,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
};

/// HTTP versions
pub const Version = enum(u1) { @"1.0", @"1.1" };

/// Represents a single HTTP header.
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

// HTTP methods interpreted as integers
const GET_: u32 = @bitCast([4]u8{ 'G', 'E', 'T', ' ' });
const HEAD: u32 = @bitCast([4]u8{ 'H', 'E', 'A', 'D' });
const POST: u32 = @bitCast([4]u8{ 'P', 'O', 'S', 'T' });
const PUT_: u32 = @bitCast([4]u8{ 'P', 'U', 'T', ' ' });
const DELE: u32 = @bitCast([4]u8{ 'D', 'E', 'L', 'E' });
const CONN: u32 = @bitCast([4]u8{ 'C', 'O', 'N', 'N' });
const OPTI: u32 = @bitCast([4]u8{ 'O', 'P', 'T', 'I' });
const TRAC: u32 = @bitCast([4]u8{ 'T', 'R', 'A', 'C' });
const PATC: u32 = @bitCast([4]u8{ 'P', 'A', 'T', 'C' });

// HTTP versions interpreted as integers
const HTTP_1_0: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '0' });
const HTTP_1_1: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '1' });

/// Minimum bytes required for an HTTP/1.x request
///
/// `GET / HTTP/1.1\n`
const min_request_len = 0xf;

/// When `error.Incomplete` is received, caller should read more bytes to buffer
/// and retry parsing with `parseRequest`.
pub const ParseRequestError = error{ Incomplete, Invalid };

/// Helper for wandering around & parsing things along the way.
const Cursor = struct {
    /// Pointer to current position of cursor.
    idx: [*]const u8,
    /// Pointer to end of the buffer.
    end: [*]const u8,
    /// Pointer to start of the buffer.
    start: [*]const u8,

    /// Returns the current position.
    inline fn current(cursor: *const Cursor) [*]const u8 {
        return cursor.idx;
    }

    /// Returns the current character.
    inline fn char(cursor: *const Cursor) u8 {
        return cursor.idx[0];
    }

    /// Advances the position of the cursor by given value.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn advance(cursor: *Cursor, by: usize) void {
        cursor.idx += by;
    }

    /// Checks if buffer has `len` length of characters.
    /// `(cursor.end - cursor.idx >= len)`
    inline fn hasLength(cursor: *const Cursor, len: usize) bool {
        return cursor.end - cursor.idx >= len;
    }

    /// Loads a `@Vector(len, u8)` from the current position of cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn asVector(cursor: *const Cursor, len: comptime_int) @Vector(len, u8) {
        return cursor.idx[0..len].*;
    }

    /// Creates an integer from the current position of the cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    /// SAFETY: T must be an integer with bit size >= @bitSizeOf(u8).
    inline fn asInteger(cursor: *const Cursor, comptime T: type) T {
        return @bitCast(cursor.idx[0 .. @bitSizeOf(T) / @bitSizeOf(u8)].*);
    }

    /// Peek the current character but don't advance.
    inline fn peek(cursor: *const Cursor, c: u8) bool {
        return cursor.idx[0] == c;
    }

    /// Peek the current and the next but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek2(cursor: *const Cursor, c0: u8, c1: u8) bool {
        return cursor.asInteger(u16) == @as(u16, @bitCast([2]u8{ c0, c1 }));
    }

    /// Peek the current and next 2 characters but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek3(cursor: *const Cursor, c0: u8, c1: u8, c2: u8) bool {
        return cursor.idx[0] == c0 and cursor.idx[1] == c1 and cursor.idx[2] == c2;
    }

    /// Peek the current and next 3 characters but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek4(cursor: *const Cursor, c0: u8, c1: u8, c2: u8, c3: u8) bool {
        return cursor.asInteger(u32) == @as(u32, @bitCast([4]u8{ c0, c1, c2, c3 }));
    }

    /// Parses the method and the trailing space.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn parseMethod(cursor: *Cursor, method: *Method) ParseRequestError!void {
        // create an u32 out of received bytes to match the method
        const m_u32: u32 = cursor.asInteger(u32);
        // advance 4 since we just consumed 4
        cursor.advance(4);

        // we consume the method + trailing space here
        method.* = blk: switch (m_u32) {
            GET_ => {
                break :blk .get;
            },
            POST => {
                // expect space after this
                if (cursor.peek(' ')) {
                    cursor.advance(1);
                    break :blk .post;
                }

                return error.Invalid;
            },
            HEAD => {
                // expect space after this
                if (cursor.peek(' ')) {
                    cursor.advance(1);
                    break :blk .head;
                }

                return error.Invalid;
            },
            PUT_ => {
                break :blk .put;
            },
            DELE => {
                // expect `TE ` after this
                if (cursor.peek3('T', 'E', ' ')) {
                    cursor.advance(3);
                    break :blk .delete;
                }

                return error.Invalid;
            },
            CONN => {
                // expect `ECT ` after this
                if (cursor.peek4('E', 'C', 'T', ' ')) {
                    cursor.advance(4);
                    break :blk .connect;
                }

                return error.Invalid;
            },
            OPTI => {
                // expect `ONS ` after this
                if (cursor.peek4('O', 'N', 'S', ' ')) {
                    cursor.advance(4);
                    break :blk .options;
                }

                return error.Invalid;
            },
            TRAC => {
                // expect `E ` after this
                if (cursor.peek2('E', ' ')) {
                    cursor.advance(2);
                    break :blk .trace;
                }

                return error.Invalid;
            },
            PATC => {
                // expect 'H ' after this
                if (cursor.peek2('H', ' ')) {
                    cursor.advance(2);
                    break :blk .patch;
                }

                return error.Invalid;
            },
            else => return error.Invalid,
        }; // method + trailing space is consumed
    }

    /// Validates path characters and advances the cursor as much as validated.
    inline fn matchPath(cursor: *Cursor) void {
        // SIMD (vectorized) search
        if (comptime use_vectors) {
            // Prefer vectored search as much as possible.
            while (cursor.hasLength(vec_size)) {
                // Fill a vector with DEL.
                const deletes: @Vector(vec_size, u8) = @splat(0x7f);
                // Fill a vector with spaces.
                const spaces: @Vector(vec_size, u8) = @splat(' ');

                // Load the next chunk from the buffer.
                const chunk = cursor.asVector(vec_size);

                // This does couple of things;
                // * If a char in `chunk` is greater than a space character (32), put a `true` at it's index (false otherwise),
                // * If chunk includes a DEL character (127), put a `false` at it's index (true otherwise),
                // * Glue comparisons via AND NOT (a & ~b).
                //
                // In the end, we have a bitmask where invalid chars are represented as zeroes and valid chars as ones.
                const bits = @intFromBool(chunk > spaces) & ~@intFromBool(chunk == deletes);

                // Cursor will be advanced by this value. If this is not equal to `vec_size`, an invalid char is found.
                // Invalid chars include the space char too, which is also the delimiter of path section.
                const adv_by = @ctz(~@as(VectorInt, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or space, we're done
                if (adv_by != vec_size) {
                    return;
                }
            }
        }

        // SWAR search
        while (cursor.hasLength(block_size)) {
            // Fill the largest integer with exclamation marks.
            const bangs = comptime broadcast(usize, '!');
            // Fill the largest integer with DEL.
            const del = comptime broadcast(usize, 0x7f);
            // Fill the largest integer with 1.
            const one = comptime broadcast(usize, 0x01);
            // Fill the largest integer with € (128).
            const full_128 = comptime broadcast(usize, 128);
            // Load the next chunk.
            const chunk = cursor.asInteger(usize);

            // * When a byte in `chunk` is less than `!`, subtraction will wrap around and set the high bit.
            // * The AND NOT part is to make sure only the high bits of characters less than `!` be set.
            const lt = (chunk -% bangs) & ~chunk;

            const xor_del = chunk ^ del;
            const eq_del = (xor_del -% one) & ~xor_del; // == DEL

            // * Create a bitmask out of high bits and count trailing zeroes.
            // * Dividing by byte size (>> 3) converts the bit position to byte index.
            const adv_by = @ctz((lt | eq_del) & full_128) >> 3;

            // advance the cursor
            cursor.advance(adv_by);

            // chunk includes an invalid char or space, we're done
            if (adv_by != block_size) {
                return;
            }
        }

        // last resort, scalar search
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidPathChar(cursor.char())) {
                return;
            }
        }
    }

    /// Parses the path, must be called after `parseMethod`.
    inline fn parsePath(cursor: *Cursor, path: *?[]const u8) ParseRequestError!void {
        // We assume this is called after `parseMethod`.
        const path_start = cursor.current();
        // validate path characters
        cursor.matchPath();
        // after `matchPath` returns, we're at where path ends
        const path_end = cursor.current();

        // Make sure the char caused `matchPath` to return is a space.
        if (cursor.char() == ' ') {
            @branchHint(.likely); // likely go down here

            // set path
            path.* = path_start[0 .. path_end - path_start];

            // skip the space
            cursor.advance(1);
            // done
            return;
        }

        // If we got here we've either;
        // * Found an invalid character that's not space (32),
        // * Reached end of the buffer so this is likely a partial request.
        if (path_end == cursor.end) {
            // No remaining bytes, though the caller can read more data and try to parse again.
            return error.Incomplete;
        }

        // Invalid character and not end of the buffer, so a malformed request. Can't go further.
        return error.Invalid;
    }

    /// Parses the HTTP version and the trailing CRLF (or just LF), must be called after `parsePath`.
    inline fn parseVersion(cursor: *Cursor, version: *Version) ParseRequestError!void {
        // We need at least 9 chars to parse the version and trailing CRLF.
        // `HTTP/1.1\n` => 9, `HTTP/1.1\r` => 9, `HTTP/1.1\r\n` => 10.
        //
        // We'll likely receive line endings formatted as `\r\n`, but the senders are free to just provide `\n`.
        if (cursor.end - cursor.current() < 9) {
            return error.Incomplete;
        }

        // Create an integer from current index.
        const chunk = cursor.asInteger(u64);
        // advance as much as consumed
        cursor.advance(8);

        // Match the version with magic integers.
        version.* = blk: switch (chunk) {
            HTTP_1_0 => break :blk .@"1.0",
            HTTP_1_1 => break :blk .@"1.1",
            else => return error.Invalid, // Unknown/unsupported HTTP version.
        };

        // Parse trailing CRLF.
        // Current character must be either `\r` or `\n`.
        switch (cursor.char()) {
            '\n' => cursor.advance(1), // advance by 1 and return, we're done here
            '\r' => {
                // move forward
                cursor.advance(1);
                // check if is this the end
                if (cursor.current() == cursor.end) {
                    // caller can read more and retry
                    return error.Incomplete;
                }

                // received `\r\n`
                if (cursor.char() == '\n') {
                    @branchHint(.likely);
                    // advance and return
                    cursor.advance(1);
                    return;
                } else {
                    // unexpected character so a malformed request
                    return error.Invalid;
                }
            },
            inline else => return error.Invalid, // unroll
        }
    }

    /// Validates header keys.
    /// Prefers SSE (128-bits) instead since header keys are rather small.
    inline fn matchHeaderKey(cursor: *Cursor) void {
        if (comptime use_vectors) {
            const sse_vec_size = 16;
            const Vec = @Vector(sse_vec_size, u8);
            const Int = std.meta.Int(.unsigned, sse_vec_size);

            while (cursor.hasLength(sse_vec_size)) {
                const spaces: Vec = @splat(' ');
                const colons: Vec = @splat(':');
                const deletes: Vec = @splat(0x7f);

                const chunk = cursor.asVector(sse_vec_size);

                const bits = @intFromBool(chunk > spaces) & ~(@intFromBool(chunk == colons) | @intFromBool(chunk == deletes));

                const adv_by = @ctz(~@as(Int, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or CRLF, we're done
                if (adv_by != sse_vec_size) {
                    return;
                }
            }
        }

        // NOTE: SWAR is not preferred here, this might change in the future
        // but honestly header keys are not so long.

        // fallback for len < 16
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidKeyChar(cursor.char())) {
                return;
            }
        }
    }

    /// Validates header values.
    inline fn matchHeaderValue(cursor: *Cursor) void {
        // Unlike headers keys, prefer vectors initially when validating header values if possible.
        if (comptime use_vectors) {
            while (cursor.hasLength(vec_size)) {
                // Fill a vector with TAB (\t, 9).
                //const tabs: @Vector(vec_size, u8) = @splat(0x9);
                // Fill a vector with DEL (127).
                const deletes: @Vector(vec_size, u8) = @splat(0x7f);
                // Fill a vector with US (31).
                const full_31: @Vector(vec_size, u8) = @splat(0x1f);
                // Load the next chunk from the buffer.
                const chunk = cursor.asVector(vec_size);

                //const bits = @intFromBool(chunk > full_31) | @intFromBool(chunk == tabs) & ~@intFromBool(chunk == deletes);
                const bits = @intFromBool(chunk > full_31) & ~@intFromBool(chunk == deletes);

                const adv_by = @ctz(~@as(VectorInt, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or CRLF, we're done
                if (adv_by != vec_size) {
                    return;
                }
            }
        }

        // SWAR search
        while (cursor.hasLength(block_size)) {
            const bangs = comptime broadcast(usize, ' ');
            const ones = comptime broadcast(usize, 0x01);
            const dels = comptime broadcast(usize, 0x7f);
            const full_128 = comptime broadcast(usize, 128);

            const chunk = cursor.asInteger(usize);

            const lt = (chunk -% bangs) & ~chunk;

            const xor_dels = chunk ^ dels;
            const eq_del = (xor_dels -% ones) & ~xor_dels;

            const adv_by = @ctz((lt | eq_del) & full_128) >> 3;

            cursor.advance(adv_by);

            // chunk includes an invalid char or space, we're done
            if (adv_by != block_size) {
                return;
            }
        }

        // fallback, scalar search
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidValueChar(cursor.char())) {
                return;
            }
        }
    }

    /// Parses a single header.
    inline fn parseHeader(cursor: *Cursor, header: *Header) ParseRequestError!void {
        const key_start = cursor.current();
        cursor.matchHeaderKey();
        const key_end = cursor.current();

        // Make sure the invalid character is a colon (58).
        switch (cursor.char()) {
            ':' => {
                @branchHint(.likely);

                // This means 0 length header key, which is invalid.
                if (key_end == key_start) {
                    return error.Invalid;
                }

                // move forward
                cursor.advance(1);
            },
            inline else => {
                // If we got here we've either;
                // * Found an invalid character that's not colon (58),
                // * Reached end of the buffer so this is likely a partial request.
                if (key_end == cursor.end) {
                    // No remaining bytes, though the caller can read more data and try to parse again.
                    return error.Incomplete;
                }

                // Invalid character and not end of the buffer, so a malformed request. Can't go further.
                return error.Invalid;
            },
        }

        // Get rid of leading spaces if there are any.
        while (cursor.end - cursor.current() > 0 and cursor.char() == ' ') : (cursor.advance(1)) {}

        // Found where header value starts.
        const val_start = cursor.current();
        cursor.matchHeaderValue();
        const val_end = cursor.current();

        switch (cursor.char()) {
            // Both `\n` and `\r\n` indicate the end of value part.
            '\n' => cursor.advance(1),
            '\r' => {
                cursor.advance(1);

                // If there are no bytes, request is partial since we need a `\n` character too.
                if (cursor.current() == cursor.end) {
                    return error.Incomplete;
                }

                // Check for not `\n`.
                if (cursor.char() != '\n') {
                    @branchHint(.unlikely);
                    return error.Invalid;
                }

                // move forward
                cursor.advance(1);
            },
            // Any other character is invalid.
            inline else => {
                if (val_end == cursor.end) {
                    return error.Incomplete;
                }

                // Invalid character and not end of the buffer, so a malformed request. Can't go further.
                return error.Invalid;
            },
        }

        // Header is set.
        header.* = .{
            .key = key_start[0 .. key_end - key_start],
            .value = val_start[0 .. val_end - val_start],
        };
    }

    /// Parses HTTP request headers.
    /// If the provided `Headers` length is not sufficient, it returns `error.TooManyHeaders`.
    inline fn parseHeaders(cursor: *Cursor, headers: []Header, count: *usize) ParseRequestError!void {
        var i: usize = 0;
        while (i < headers.len) : (i += 1) {
            // check if headers part has finished
            switch (cursor.char()) {
                '\n' => {
                    cursor.advance(1);
                    // end of headers
                    count.* = i;
                    return;
                },
                '\r' => {
                    cursor.advance(1);

                    if (cursor.current() == cursor.end) {
                        return error.Incomplete;
                    }

                    if (cursor.char() != '\n') {
                        return error.Invalid;
                    }

                    cursor.advance(1);
                    // end of headers
                    count.* = i;
                    return;
                },
                else => {},
            }

            try cursor.parseHeader(&headers[i]);
        }

        // Set count to highest.
        count.* = i;

        // We have to check for ending CRLF, same as what we're doing at top.
        switch (cursor.char()) {
            '\n' => cursor.advance(1),
            '\r' => {
                cursor.advance(1);

                if (cursor.current() == cursor.end) {
                    return error.Incomplete;
                }

                if (cursor.char() != '\n') {
                    @branchHint(.unlikely);
                    return error.Invalid;
                }

                cursor.advance(1);
            },
            else => {
                // If we got here, we either;
                // * have too many headers and not enough space in `headers`,
                // * or just received an invalid character.
                //
                // NOTE: Currently either possibilities are interpreted as `error.Invalid`, this might change in the future.
                return error.Invalid;
            },
        }
    }
};

/// Table of valid path characters.
const path_map = createCharMap(.{
    // Invalid characters.
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, ' ', 127,
});

/// Checks if a given character is a valid path character.
inline fn isValidPathChar(c: u8) bool {
    return path_map[c] != 0;
}

/// Table of valid header key characters.
const key_map = createCharMap(.{
    // Invalid characters.
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, ':', 127,
});

/// Checks if a given character is a valid header key character.
inline fn isValidKeyChar(c: u8) bool {
    return key_map[c] != 0;
}

/// Table of valid header value characters.
const value_map = createCharMap(.{
    // Invalid characters.
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127,
});

/// Checks if a given character is a valid header value character.
inline fn isValidValueChar(c: u8) bool {
    return value_map[c] != 0;
}

/// Returns an integer filled with a given byte.
inline fn broadcast(comptime T: type, byte: u8) T {
    comptime {
        const bits = @ctz(@as(T, 0));
        const b = @as(T, byte);

        return switch (bits) {
            8 => b * 0x01,
            16 => b * 0x01_01,
            32 => b * 0x01_01_01_01,
            64 => b * 0x01_01_01_01_01_01_01_01,
            else => @compileError("unexpected broadcast size"),
        };
    }
}

/// Returns a table of 8-bit characters where zeros are invalid and ones are valid.
inline fn createCharMap(comptime invalids: anytype) [256]u1 {
    comptime {
        var map: [256]u1 = undefined;
        // Set each index initially.
        @memset(&map, 1);

        // Unset invalid characters.
        for (invalids) |c| map[c] = 0;

        return map;
    }
}

// Public API

/// Parses an HTTP request.
/// * `error.Incomplete` indicates more data is needed to complete the request.
/// * `error.Invalid` indicates request is invalid/malformed.
pub fn parseRequest(
    // Slice we want to parse.
    slice: []const u8,
    /// Parsed method. Will be set to `.unknown` initially.
    method: *Method,
    /// Parsed path. Will be set to `null` initially.
    path: *?[]const u8,
    /// Parsed HTTP version. Will be set to `.@"1.0"` initially.
    version: *Version,
    /// Parsed headers will be found here.
    headers: []Header,
    header_count: *usize,
) ParseRequestError!usize {
    // We expect at least 15 bytes to start processing.
    if (slice.len < min_request_len) {
        return error.Incomplete;
    }

    // Pointer to start of the buffer.
    const slice_start = slice.ptr;
    // Pointer to end of the buffer
    const slice_end = slice.ptr + slice.len;

    // The cursor helps walking through bytes and parsing things.
    // I should better rename it to `Parser` since it's use cases are more similar to it.
    var cursor = Cursor{ .idx = slice_start, .end = slice_end, .start = slice_start };

    // parse the method
    try cursor.parseMethod(method);
    // parse the path
    try cursor.parsePath(path);
    // parse the HTTP version
    try cursor.parseVersion(version);
    // parse HTTP headers
    try cursor.parseHeaders(headers, header_count);

    // Return the total consumed length to caller.
    return cursor.idx - cursor.start;
}

// Tests

test parseRequest {
    const buffer: []const u8 = "TRACE /cookies HTTP/1.1\r\nHost: asdjqwdkwfj\r\nConnection: keep-alive\r\n\r\n";

    var method: Method = .unknown;
    var path: ?[]const u8 = null;
    var http_version: Version = .@"1.0";
    var headers: [64]Header = undefined;
    var header_count: usize = 0;

    const len = parseRequest(buffer[0..], &method, &path, &http_version, &headers, &header_count) catch |err| switch (err) {
        error.Incomplete => @panic("need more bytes"),
        error.Invalid => @panic("invalid!"),
    };

    std.debug.print("{}\t{}\n", .{ method, http_version });
    std.debug.print("path: {s}\n", .{path.?});

    for (headers[0..header_count]) |header| {
        std.debug.print("{s}\t{s}\n", .{ header.key, header.value });
    }

    std.debug.print("len: {any}\n", .{len});

    //var tokens: [256]u1 = std.mem.zeroes([256]u1);
    //@memset(&tokens, 1);
    //
    //tokens[58] = 0;
    //tokens[127] = 0;
    //
    //for (0..32) |i| {
    //    tokens[i] = 0;
    //}
    //
    //std.debug.print("{any}\n", .{tokens});

    //const min: @Vector(8, u8) = @splat('A' - 1);
    //const max: @Vector(8, u8) = @splat('Z');
    //
    //const chunk: @Vector(8, u8) = "tEsTINgG".*;
    //
    //const bits = @intFromBool(chunk <= max) & @intFromBool(chunk > min);
    //var res: u8 = @bitCast(bits);
    //
    //while (res != 0) {
    //    const t = res & -%res;
    //    defer res ^= t;
    //
    //    const idx = @ctz(t);
    //    std.debug.print("{c}\n", .{chunk[idx]});
    //}
}
