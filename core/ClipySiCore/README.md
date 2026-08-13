# ClipySiCore

Swift bindings for the shared Rust core (`clipy-si-core`) — secret detection/masking,
cryptography, and the record/vault/sync formats. The macOS app links this as a Swift
package; the heavy lifting lives in a prebuilt, statically-linked `ClipySiCoreFFI.xcframework`.

The Rust implementation is developed in a separate repository and is not included here.
This package contains only:

- `Sources/ClipySiCore/clipy_si_core_ffi.swift` — the committed, generated UniFFI Swift glue.
- `Package.swift` — declares the binary `ClipySiCoreFFI` target.

## How the binary is resolved

`Package.swift` picks one of two sources for `ClipySiCoreFFI`:

1. **Local XCFramework (development).** If `ClipySiCoreFFI.xcframework` is present next to
   `Package.swift` (git-ignored), it is used directly. This lets you build the app from a
   locally built core without a published release.
2. **GitHub Release asset (default).** Otherwise the framework is downloaded from this
   repository's GitHub Release via `binaryTarget(url:checksum:)`, with the SHA-256 pinned in
   `Package.swift`. This is what CI and external contributors use.

## Cutting a release of the core binary

The XCFramework is produced from the core repository (`./build-xcframework.sh`, universal
arm64 + x86_64). Publish the asset **before** committing anything that references it, so
`main` never points at a URL that does not resolve yet:

```bash
# 1. Build the universal XCFramework from the core repo, then zip it:
ditto -c -k --sequesterRsrc --keepParent ClipySiCoreFFI.xcframework ClipySiCoreFFI.xcframework.zip

# 2. Compute the checksum SwiftPM will verify (the zip is NOT deterministic — this checksum
#    matches only this exact zip, so upload the very file you computed it from):
swift package compute-checksum ClipySiCoreFFI.xcframework.zip

# 3. Create the GitHub Release for the new unique tag and upload
#    ClipySiCoreFFI.xcframework.zip as an asset. If the tag is not an app release,
#    pass --latest=false so releases/latest (the Sparkle appcast URL) keeps
#    pointing at the newest app release.

# 4. In this package's Package.swift, set the binaryTarget url to that release asset and
#    paste the checksum from step 2. Land this in the SAME commit as any code that needs
#    the new core API, and push only after step 3 is live.
```

After the release exists, a fresh `git clone` of the app builds without any local XCFramework,
because SwiftPM downloads and checksum-verifies the asset. Verify that path before pushing:
the local-XCFramework override (resolution rule 1 above) means a machine that built the core
locally never exercises the url/checksum pin — test the pin from a clean clone (or with the
local `ClipySiCoreFFI.xcframework` moved away).
