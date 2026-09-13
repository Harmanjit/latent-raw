# Vendored native dependencies

LibRaw (and later Lensfun) are built as XCFrameworks here rather than pulled
in as SwiftPM package dependencies, for two reasons: we need arm64-only,
Metal-adjacent build flags (no OpenMP — Latent does its own parallelism),
and we want a pinned, reproducible binary checked into CI rather than a
source build that could pick up an unexpected LibRaw version.

## Prerequisites (Homebrew)

```bash
brew install autoconf automake libtool pkg-config
```

## Building LibRaw (run this on macOS)

Confirm the current stable tag first — don't trust a hardcoded version here,
it goes stale:

```bash
git ls-remote --tags --sort=-v:refname https://github.com/LibRaw/LibRaw.git | head -5
```

Then, with `LIBRAW_TAG` set to whatever that showed as newest (0.22.1 as of
this writing, but verify):

```bash
cd vendor
LIBRAW_TAG=0.22.2   # <-- confirm with the command above, don't assume this

git clone --branch "$LIBRAW_TAG" --depth 1 https://github.com/LibRaw/LibRaw.git libraw-src
cd libraw-src

autoreconf --install
./configure --host=aarch64-apple-darwin \
            --disable-shared --enable-static \
            --disable-openmp \
            CFLAGS="-arch arm64 -mmacosx-version-min=15.0" \
            CXXFLAGS="-arch arm64 -mmacosx-version-min=15.0"
make -j"$(sysctl -n hw.ncpu)"
```

(A `ld: warning: -bind_at_load is deprecated` during `make` is harmless —
it's libtool passing an old flag on newer toolchains. Ignore it unless the
build actually fails.)

Package the result as an XCFramework. **Delete any previous output first** —
`xcodebuild -create-xcframework` refuses to write into a path that already
has content, which is what caused the "couldn't be copied... item with the
same name already exists" error. Don't pre-create the `macos-arm64/` folder
yourself; xcodebuild builds that structure itself from the `-library` flag:

```bash
rm -rf ../LibRaw.xcframework   # safe even if it doesn't exist yet

xcodebuild -create-xcframework \
  -library lib/.libs/libraw.a -headers libraw \
  -output ../LibRaw.xcframework
```

Pin the exact tag you used at the top of this file once Phase 0 confirms it
covers the D750/A7 III/Canon CR2+CR3 combination cleanly, so a future clone
of this repo is reproducible.

## macOS version target

Latent's minimum deployment target is **macOS 15 (Sequoia)**, and it must
also run correctly on macOS 26 (Tahoe). This matters for the build flags
above (`-mmacosx-version-min=15.0`) and for anything in `PixelEngine` that
reaches for a Metal 4-only API — see the note in `GPUContext.swift`.

## Why not OpenMP

LibRaw's own multi-threading (via OpenMP) would compete with Swift's
structured concurrency and GCD's QoS scheduling for the same performance
cores, with no coordination between the two. Latent disables it and does
all its own parallel dispatch, per the efficiency rules in DESIGN.md.

## Lensfun

Not needed until Phase 4 (lens corrections). When the time comes, build it
the same way: a static arm64 library plus its XML lens database, which
ships as data files rather than code and can be updated independently.
