# Security and Privacy

## No network

Latent makes no network requests. There is no telemetry, analytics, crash reporting or update check. The app bundle has no network entitlement, so the operating system enforces this: the process cannot open a socket.

## Sandbox and hardened runtime

The app runs in the App Sandbox with the hardened runtime, signed ad hoc. It can reach only folders you choose in an open panel, remembered between launches by security-scoped bookmark, plus its own container under `~/Library/Containers/com.latent.app`. No Apple developer account is involved; the sandbox is enforced from the signature regardless.

## Isolated raw decoding

Raw files are parsed by LibRaw, a large C++ library that processes files you did not create. Latent runs it in a separate XPC service, `LatentRawDecoder.xpc`, sandboxed with no file access and no network. The app hands it an open file descriptor per file and receives pixels back. A crafted file that exploits the decoder gets a process that can do nothing, and the app shows an error instead of crashing.

## Parsers

XMP sidecars are parsed with external entities disabled and a size cap. Folder scans never follow symlinks. Export file names are sanitised. Database access is parameterised throughout.

## Supply chain

LibRaw is pinned by commit hash and refused if the tag moves. The one Swift dependency is pinned to an exact version. Model weights are pinned by repository revision and SHA-256 in the conversion scripts. Dependabot watches the Actions and Python dependencies.

## What is written, and where

- `_latent/` inside each photo folder: catalog, sidecars, thumbnails. Nothing else in your folders is touched.
- The app container: preferences, compiled models, saved presets.
- Exports: only where you choose; metadata can be stripped.
- The unified log receives failure messages with file names marked private.
