# ClipySiCore

Swift bindings for the shared Rust core (`clipy-si-core`) — secret detection/masking,
cryptography, and the record/vault/sync formats. The macOS app links this as a Swift
package; the heavy lifting lives in a prebuilt, statically-linked `ClipySiCoreFFI.xcframework`.

The Rust implementation is open source at
[ClipySi/clipy-si-core](https://github.com/ClipySi/clipy-si-core).
This package contains only:

- `Sources/ClipySiCore/clipy_si_core_ffi.swift` — the committed, generated UniFFI Swift glue.
- `Package.swift` — declares the binary `ClipySiCoreFFI` target.

## How the binary is resolved

`Package.swift` picks one of two sources for `ClipySiCoreFFI`:

1. **Local XCFramework (development).** If `ClipySiCoreFFI.xcframework` is present next to
   `Package.swift` (git-ignored), it is used directly. This lets you build the app from a
   locally built core without a published release.
2. **GitHub Release asset (default).** Otherwise the framework is downloaded from the
   core repository's GitHub Release via `binaryTarget(url:checksum:)`, with the SwiftPM
   checksum pinned in `Package.swift`. This is what CI and external contributors use.
   Each core release carries a build-provenance attestation; the release notes include
   the exact `gh attestation verify` invocation to check the asset yourself.

## Cutting a release of the core binary

Releases are produced by the core repository's tag-driven CI — no manual builds or
uploads. In `ClipySi/clipy-si-core`:

1. Bump `[workspace.package] version` in `Cargo.toml` (update `Cargo.lock` with
   `cargo update --workspace --offline`) and land it on `main`.
2. Push the matching `v*` tag. CI verifies (fmt / clippy / tests / cargo-deny), builds
   the universal XCFramework, runs the Swift KAT conformance tests, attests build
   provenance, and creates a **draft** release with the SwiftPM checksum in the notes.
3. Verify the draft asset (`gh attestation verify …` — the exact command is in the
   release notes), then publish it. Releases are immutable once published: a broken
   release means a new version, never a re-upload.
4. In this package's `Package.swift`, point the `binaryTarget` url at the new release
   asset and paste the checksum from the release notes. Land this in the SAME commit as
   any code that needs the new core API, and push only after the release is public.

After the release exists, a fresh `git clone` of the app builds without any local XCFramework,
because SwiftPM downloads and checksum-verifies the asset. Verify that path before pushing:
the local-XCFramework override (resolution rule 1 above) means a machine that built the core
locally never exercises the url/checksum pin — test the pin from a clean clone (or with the
local `ClipySiCoreFFI.xcframework` moved away).
