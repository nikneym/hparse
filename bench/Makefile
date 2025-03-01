bench-poop: build-picohttpparser build-httparse build-hparse
	poop -d 50000 "./picohttpparser/picohttpparser" "./bench-httparse/target/release/bench-httparse" "./hparse/zig-out/bin/hparse"

bench-poop-log:
	poop -d 10000 "./picohttpparser/picohttpparser" "./bench-httparse/target/release/bench-httparse" "./hparse/zig-out/bin/hparse" > bench.txt

bench-hyperfine: build-picohttpparser build-httparse build-hparse
	hyperfine "./hparse/zig-out/bin/hparse" "./picohttpparser/picohttpparser" "./bench-httparse/target/release/bench-httparse" --export-json bench.json

bench-poop-skylake: build-httparse-skylake build-hparse-skylake
	poop -d 10000 "./bench-httparse/target/release/bench-httparse" "./hparse/zig-out/bin/hparse"

bench-hyperfine-skylake: build-httparse-skylake build-hparse-skylake
	hyperfine -w 20 "./bench-httparse/target/release/bench-httparse" "./hparse/zig-out/bin/hparse"

build-picohttpparser:
	cd picohttpparser && make && cd ..

build-httparse:
	cd bench-httparse && cargo build --release && cd ..

build-hparse:
	cd hparse && zig build -Doptimize=ReleaseFast && cd ..

build-httparse-skylake:
	cd bench-httparse && RUSTFLAGS=-Ctarget-feature=+avx2 cargo build --release && cd ..

build-hparse-skylake:
	cd hparse && zig build -Dcpu=skylake -Doptimize=ReleaseFast && cd ..

clean:
	rm picohttpparser/picohttpparser && rm -rf bench-httparse/target && rm -rf hparse/zig-out hparse/.zig-cache
