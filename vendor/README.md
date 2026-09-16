# Vendored native dependencies

LibRaw is built as an XCFramework here rather than pulled in as a SwiftPM
package dependency, for two reasons: we need arm64-only build flags (no
OpenMP — Latent does its own parallelism), and we want a build from one
pinned, verified LibRaw commit rather than whatever version a package
resolve picks up. The XCFramework itself is not committed (it is a 20 MB
binary); each clone builds it once, and CI caches the result.

## The short version

```bash
brew install autoconf automake libtool pkg-config
scripts/build_libraw.sh        # pinned commit, idempotent; CI runs the same script
```

## What the script does

`scripts/build_libraw.sh` is the reference; this is a summary of it.

1. Clones LibRaw at tag 0.22.2 into `vendor/libraw-src`, and refuses to
   build unless the tag resolves to commit
   `b93f6e45c194f5df9b02a43b1af9a54b4f41f33f`: tags can be moved, commits
   can't. When bumping LibRaw, change `LIBRAW_TAG` and `LIBRAW_COMMIT`
   together.
2. Runs `autoreconf --install`, then `./configure` for
   `aarch64-apple-darwin`, static only, with
   `--disable-openmp --disable-jpeg --disable-lcms` and
   `-mmacosx-version-min=15.0`, so the library needs nothing beyond zlib,
   which `Package.swift` links.
3. Builds only `lib/libraw.la`. LibRaw's sample programs are C sources
   linked without the C++ runtime and fail to link on current Xcode; Latent
   never uses them.
4. Deletes any previous `vendor/LibRaw.xcframework`, packages
   `lib/.libs/libraw.a` and the `libraw` headers with
   `xcodebuild -create-xcframework`, and records the tag inside the
   framework, so a second run with the same tag does nothing.

Two messages you may see:

- `ld: warning: -bind_at_load is deprecated` during the build is harmless:
  libtool passes an old flag to newer toolchains.
- "couldn't be copied... item with the same name already exists" comes from
  `xcodebuild -create-xcframework` writing into a path that already has
  content. The script deletes the old output first. If you package by hand,
  do the same, and don't create the `macos-arm64/` folder yourself;
  xcodebuild makes that structure from the `-library` flag.

## macOS version target

Latent's minimum deployment target is **macOS 15 (Sequoia)**, and it must
also run correctly on macOS 26 (Tahoe). This matters for the build flags in
`scripts/build_libraw.sh` (`-mmacosx-version-min=15.0`) and for anything in
`PixelEngine` that reaches for a Metal 4-only API — see the note in
`GPUContext.swift`.

## Why not OpenMP

LibRaw's own multi-threading (via OpenMP) would compete with Swift's
structured concurrency and GCD's QoS scheduling for the same performance
cores, with no coordination between the two. Latent disables it and does
all its own parallel dispatch, per the efficiency rules in DESIGN.md.

## Lensfun

Lensfun's C library is not used. `LensKit` reads Lensfun's XML database,
copied at a pinned commit into `Sources/LensKit/Resources/lensfun-db` and
bundled as resources (DESIGN.md §3).
