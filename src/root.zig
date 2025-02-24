//! zero allocation, stateless and streaming HTTP parser module.
//! By streaming, it can parse partially received HTTP requests.
//! Some HTTP methods are not supported intentionally, namely `CONNECT` and `TRACE`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

//const has_avx2 = std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

// If suggested vector length is null, prefer not to use vectors!
const use_vectors = blk: {
    const recommended = std.simd.suggestVectorLength(u8);
    break :blk if (recommended == null) false else true;
};

/// This is what we use for vector sizes in vectored operations.
/// If `use_vectors` is false, this gives the default block size for the CPU.
const vec_size = blk: {
    if (std.simd.suggestVectorLength(u8)) |recommended| {
        // I'm not so familiar with AVX512 and newer SIMD stuff yet, let's stick to 32 for cases >= 64.
        break :blk if (recommended >= 64) 32 else recommended;
    } else {
        // If vectors are not recommended, we prefer the default block size.
        break :blk block_size;
    }
};

/// `vec_size` as unsigned integer type.
const VectorInt = std.meta.Int(.unsigned, vec_size);

/// Block size of the CPU.
const block_size = @sizeOf(usize);

// Get the size of a single chunk in comptime.
const BlockType = switch (block_size) {
    4 => u32,
    8 => u64,
    else => unreachable,
};

/// HTTP methods
pub const Method = enum(u8) {
    unknown,
    get,
    post,
    head,
    put,
    delete,
    options,
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
// CONNECT method is not supported
const CONN: u32 = @bitCast([4]u8{ 'C', 'O', 'N', 'N' });
const OPTI: u32 = @bitCast([4]u8{ 'O', 'P', 'T', 'I' });
// TRACE method is not supported
const TRAC: u32 = @bitCast([4]u8{ 'T', 'R', 'A', 'C' });
const PATC: u32 = @bitCast([4]u8{ 'P', 'A', 'T', 'C' });

// NOTE: This might be slower on platforms with block size < 8.
// HTTP versions interpreted as integers
const HTTP_1_0: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '0' });
const HTTP_1_1: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '1' });

/// Minimum bytes required for an HTTP/1.x request
///
/// `GET / HTTP/1.1\n`
const min_request_len = 0xf;

// NOTE: Currently not used
const token_map = [256]u1{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, // ! # $ % & ' * +
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, // 0-9
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // A-O
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, // P-Z, ^, _
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // a-o
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, // p-z, |, ~
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/// When `error.Incomplete` is received, caller should read more bytes to buffer
/// and retry parsing with `parseRequest`.
pub const ParseRequestError = error{ Incomplete, Invalid };

/// Helper for wandering around & parsing things along the way.
const Cursor = struct {
    /// Pointer to current position of cursor.
    idx: [*]const u8,
    /// Pointer to start of the buffer.
    start: [*]const u8,
    /// Pointer to end of the buffer.
    end: [*]const u8,

    /// Creates a new cursor.
    fn init(start: [*]const u8, end: [*]const u8) Cursor {
        return .{ .idx = start, .start = start, .end = end };
    }

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
            OPTI => {
                // expect `ONS ` after this
                if (cursor.peek4('O', 'N', 'S', ' ')) {
                    cursor.advance(4);
                    break :blk .options;
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

    /// TODO: we might want to separate the searches to related functions.
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
        // FIXME: This is missing checks for 0x7f (DEL)
        // It's better to stick to platform's block size rather than blindly using 64bit integers.
        while (cursor.hasLength(block_size)) {
            // Fill the largest integer with exclamation marks.
            const bangs = comptime uniformBlock(BlockType, '!');
            // Fill the largest integer with 128.
            const full_128 = comptime uniformBlock(BlockType, 128);
            // Load the next chunk.
            const chunk = cursor.asInteger(BlockType);

            // * When a byte in `chunk` is less than `!`, subtraction will wrap around and set the high bit.
            // * The AND NOT part is to make sure only the high bits of characters less than `!` be set.
            const lt = (chunk -% bangs) & ~chunk;

            // * Create a bitmask out of high bits and count trailing zeroes.
            // * Dividing by byte size (>> 3) converts the bit position to byte index.
            const adv_by = @ctz(lt & full_128) >> 3;

            // advance the cursor
            cursor.advance(adv_by);

            // chunk includes an invalid char or space, we're done
            if (adv_by != block_size) {
                return;
            }
        }

        // NOTE: I believe we can do SWAR for >= 4 at here, for 64-bit platforms.

        // last resort, scalar search
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            switch (cursor.char()) {
                // invalid chars
                0...' ', 0x7f => return,
                inline else => continue, // unroll
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
            // likely go down here
            @branchHint(.likely);

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

    /// Validate header values.
    inline fn matchHeaderValue(cursor: *Cursor) void {
        // Prefer vectorized searches for header values.
        if (comptime use_vectors) {
            while (cursor.hasLength(vec_size)) {
                // Fill a vector with TAB (\t, 9).
                const tabs: @Vector(vec_size, u8) = @splat(0x9);
                // Fill a vector with DEL (127).
                const deletes: @Vector(vec_size, u8) = @splat(0x7f);
                // Fill a vector with US (31).
                const full_31: @Vector(vec_size, u8) = @splat(0x1f);
                // Load the next chunk from the buffer.
                const chunk = cursor.asVector(vec_size);

                const bits = @intFromBool(chunk > full_31) | @intFromBool(chunk == tabs) & ~@intFromBool(chunk == deletes);

                const adv_by = @ctz(~@as(VectorInt, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // FIXME: EVERYTHING INCOMPLETE

                // chunk includes an invalid char or CRLF, we're done
                if (adv_by != vec_size) {
                    return;
                }
            }
        }
    }

    /// Parses a single header.
    inline fn parseHeader(cursor: *Cursor, header: *Header) ParseRequestError!void {
        // Initially, we should be at where header starts.
        const key_start = cursor.current();
        // We can prefer vectored search here, though header keys are generally short so it might be an overkill.
        swar.matchHeaderKey(cursor);
        const key_end = cursor.current();

        // Make sure the top character is a colon (58).
        if (cursor.char() == ':') {
            // likely go down here
            @branchHint(.likely);

            // move forward
            cursor.advance(1);

            // 0 length header keys are basically invalid.
            if (cursor.current() == cursor.end) {
                return error.Invalid;
            }

            // Set the header key.
            header.key = key_start[0 .. key_end - key_start];

            // Also check if the char is space (32), we can skip it.
            if (cursor.char() == ' ') {
                @branchHint(.likely);
                cursor.advance(1);
            }
        } else {
            return error.Invalid;
        }

        // Got the header key, continue with header value.
        const val_start = cursor.current();
        cursor.matchHeaderValue();
        const val_end = cursor.current();

        std.debug.print("{s}\n", .{val_start[0 .. val_end - val_start]});
    }

    /// Parses HTTP request headers.
    /// If the provided `Headers` length is not sufficient, it returns `error.TooManyHeaders`.
    inline fn parseHeaders(cursor: *Cursor) ParseRequestError!void {
        var header: Header = undefined;
        try cursor.parseHeader(&header);

        std.debug.print("{s}\n", .{header.key});
    }
};

const swar = struct {
    /// Validates header key.
    /// TODO: Documentation for what's going on here.
    inline fn matchHeaderKey(cursor: *Cursor) void {
        while (cursor.hasLength(block_size)) {
            const bangs = comptime uniformBlock(BlockType, '!');
            const colons = comptime uniformBlock(BlockType, ':');
            const ones = comptime uniformBlock(BlockType, 0x01);
            const full_127 = comptime uniformBlock(BlockType, 0x7f);
            const full_128 = comptime uniformBlock(BlockType, 128);

            const chunk = cursor.asInteger(BlockType);

            const lt = (chunk -% bangs) & ~chunk;

            const xor_colons = chunk ^ colons;
            const eq_colon = (xor_colons - ones) & ~xor_colons;

            const xor_127 = chunk ^ full_127;
            const eq_127 = (xor_127 - ones) & ~xor_127;

            const adv_by = @ctz((lt | eq_127 | eq_colon) & full_128) >> 3;

            cursor.advance(adv_by);

            // chunk includes an invalid char or space, we're done
            if (adv_by != block_size) {
                return;
            }
        }

        // Do a scalar search if there are bytes < block_size.
        while (cursor.end - cursor.idx > 0) {
            switch (cursor.char()) {
                // invalid chars
                0...' ', ':', 0x7f => return,
                inline else => cursor.advance(1), // unroll
            }
        }
    }
};

/// Returns an integer filled with a given byte.
inline fn uniformBlock(comptime T: type, byte: u8) T {
    comptime {
        const bits = @ctz(@as(T, 0));
        const b = @as(T, byte);

        return switch (bits) {
            8 => b * 0x01,
            16 => b * 0x01_01,
            32 => b * 0x01_01_01_01,
            64 => b * 0x01_01_01_01_01_01_01_01,
            else => unreachable,
        };
    }
}

/// Parses an HTTP request.
/// * `error.Incomplete` indicates more data is needed to complete the request.
/// * `error.Invalid` indicates request is invalid/malformed.
pub fn parseRequest(
    /// Pointer to start of the buffer.
    slice_start: [*]const u8,
    /// Pointer to end of the buffer.
    slice_end: [*]const u8,
    /// Parsed method. Will be set to `.unknown` initially.
    method: *Method,
    /// Parsed path. Will be set to `null` initially.
    path: *?[]const u8,
    /// Parsed HTTP version. Will be set to `.@"1.0"` initially.
    version: *Version,
) ParseRequestError!void {
    // We expect at least 15 bytes to start processing.
    if (slice_end - slice_start < min_request_len) {
        return error.Incomplete;
    }

    // reset the method
    method.* = .unknown;
    // reset the path
    path.* = null;
    // reset the version, default given version is 1.0
    version.* = .@"1.0";

    // The cursor helps walking through bytes and parsing things.
    // I should better rename it to `Parser` since it's use cases are more similar to it.
    var cursor = Cursor.init(slice_start, slice_end);

    // parse the method
    try cursor.parseMethod(method);
    // parse the path
    try cursor.parsePath(path);
    // parse the HTTP version
    try cursor.parseVersion(version);
    // TODO: implement parsing headers
    try cursor.parseHeaders();
}

// tests

test parseRequest {
    const buffer = comptimePrint("OPTIONS /tam-41-uzunlugunda-bir-http-path-i-yazma HTTP/1.1\r\nConnection", .{});

    var method: Method = .unknown;
    var path: ?[]const u8 = null;
    var http_version: Version = .@"1.0";

    parseRequest(buffer.ptr, buffer.ptr + buffer.len, &method, &path, &http_version) catch |err| switch (err) {
        error.Incomplete => std.debug.print("need more bytes\n", .{}),
        error.Invalid => std.debug.print("invalid!\n", .{}),
    };

    std.debug.print("HTTP method: {}\nHTTP version: {}\n", .{ method, http_version });
    std.debug.print("path: {?s}\n", .{path});
}
