<p align="center">
  <img src="https://github.com/nikneym/hparse/blob/main/misc/cog.png" alt="hparse-cog" />
</p>

# hparse

![GitHub License](https://img.shields.io/github/license/nikneym/hparse?color=navy)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/nikneym/hparse/test-x86_64-linux.yml?label=x86_64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/nikneym/hparse/test-x86_64-windows.yml?label=x86_64-windows)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/nikneym/hparse/test-macos.yml?label=macos)

Fast HTTP/1.1 & HTTP/1.0 parser. Powered by Zig ⚡

## Features

* Cross-platform SIMD vectorization through Zig's `@Vector`,
* Streaming first; can be easily integrated to event loops,
* Handles partial requests,
* Never allocates and never copies.
* Similar API to picohttpparser; can be swapped in smoothly.

## Usage

```zig
const buffer: []const u8 = "GET /hello-world HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

// initialize with default values
var method: Method = .unknown;
var path: ?[]const u8 = null;
var http_version: Version = .@"1.0";
var headers: [32]Header = undefined;
var header_count: usize = 0;

// parse the request
_ = try hparse.parseRequest(
    buffer[0..],
    &method,
    &path,
    &http_version,
    &headers,
    &header_count,
);
```

## Installation

Install via Zig package manager (Copy the full SHA of latest commit hash from GitHub):

```sh
zig fetch --save https://github.com/nikneym/hparse/archive/<latest-commit-hash>.tar.gz
```

In your `build` function at `build.zig`, make sure your build step and source files are aware of the module:

```zig
const dep_opts = .{ .target = target, .optimize = optimize };

const hparse_dep = b.dependency("hparse", dep_opts);
const hparse_module = hparse_dep.module("hparse");

exe_mod.addImport("hparse", hparse_module);
```

## Acknowledgements

This project wouldn't be possible without these other projects and posts:

* [h2o/picohttpparser](https://github.com/h2o/picohttpparser)
* [seanmonstar/httparse](https://github.com/seanmonstar/httparse)
* [SIMD with Zig by Karl Seguin](https://www.openmymind.net/SIMD-With-Zig/)
* [SWAR explained: parsing eight digits by Daniel Lemire](https://lemire.me/blog/2022/01/21/swar-explained-parsing-eight-digits/)
* [Bit Twiddling Hacks by Sean Eron Anderson](https://graphics.stanford.edu/~seander/bithacks.html)

## License

MIT.
