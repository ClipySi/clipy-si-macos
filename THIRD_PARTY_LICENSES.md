# Third-Party Licenses

ClipySi is distributed **unsandboxed** as a Developer ID-signed, notarized `.app`
with Swift Package Manager dependencies and a statically linked Rust core. This
file aggregates copyright and license notices for redistributed components, and
also lists build/test pins where that is useful for auditability.

ClipySi's own source is MIT-licensed; see [LICENSE](LICENSE) and
[LICENSE_CLIPMENU](LICENSE_CLIPMENU) for the upstream Clipy / ClipMenu attribution
chain.

> **Maintainer note:** when dependencies change, refresh this file. The Swift list
> mirrors the tracked `Package.resolved` files — the app's
> `Clipy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and the
> migration tool's `tools/clipy-realm-export/Package.resolved`; the Rust list can be
> regenerated from the core's `Cargo.lock` (e.g. with `cargo about generate` or
> `cargo bundle-licenses`).

---

## Swift Package Manager pins

| Package | Version | License | Source |
| --- | --- | --- | --- |
| AEXML | 4.7.0 | MIT | https://github.com/tadija/AEXML |
| GRDB.swift | 7.11.0 | MIT | https://github.com/groue/GRDB.swift |
| KeyHolder | 4.3.0 | MIT | https://github.com/Clipy/KeyHolder |
| Magnet | 3.5.0 | MIT | https://github.com/Clipy/Magnet |
| Sauce | 2.5.0 | MIT | https://github.com/Clipy/Sauce |
| Screeen | 2.1.0 | MIT | https://github.com/Clipy/Screeen |
| Sparkle | 2.9.2 | MIT (with bundled components under their own terms) | https://github.com/sparkle-project/Sparkle |
| sqlite-data (SQLiteData) | 1.6.2 | MIT | https://github.com/pointfreeco/sqlite-data |
| swift-structured-queries | 0.31.1 | MIT | https://github.com/pointfreeco/swift-structured-queries |
| swift-sharing | 2.8.0 | MIT | https://github.com/pointfreeco/swift-sharing |
| swift-dependencies | 1.12.0 | MIT | https://github.com/pointfreeco/swift-dependencies |
| swift-identified-collections | 1.1.1 | MIT | https://github.com/pointfreeco/swift-identified-collections |
| swift-custom-dump | 1.6.0 | MIT | https://github.com/pointfreeco/swift-custom-dump |
| swift-concurrency-extras | 1.4.0 | MIT | https://github.com/pointfreeco/swift-concurrency-extras |
| swift-clocks | 1.0.6 | MIT | https://github.com/pointfreeco/swift-clocks |
| combine-schedulers | 1.2.0 | MIT | https://github.com/pointfreeco/combine-schedulers |
| swift-perception | 2.0.10 | MIT | https://github.com/pointfreeco/swift-perception |
| xctest-dynamic-overlay | 1.9.0 | MIT | https://github.com/pointfreeco/xctest-dynamic-overlay |
| swift-snapshot-testing | 1.19.2 | MIT | https://github.com/pointfreeco/swift-snapshot-testing |
| swift-collections | 1.5.1 | Apache-2.0 with Runtime Library Exception | https://github.com/apple/swift-collections |
| swift-syntax | 603.0.1 | Apache-2.0 with Runtime Library Exception | https://github.com/swiftlang/swift-syntax |

> Some pins, such as `swift-snapshot-testing`, `swift-custom-dump`, and
> `xctest-dynamic-overlay`, are build/test dependencies rather than runtime
> frameworks shipped in `ClipySi.app`; they are listed here because they are
> present in `Package.resolved` and matter for reproducible review.

### Apache-2.0 NOTICE preservation

`swift-collections` and `swift-syntax` are licensed under **Apache License 2.0 with
the Runtime Library Exception**. Their `LICENSE.txt` / `NOTICE.txt` (and the Runtime
Library Exception) apply; see the upstream repositories linked above for the full
text. Apache-2.0 requires retaining copyright, license, and NOTICE notices in
redistributions — this section satisfies that for the bundled binaries.

---

## Rust core (`clipy-si-core`) — statically linked

The shared Rust core is statically linked into the app binary. Its runtime
dependencies are MIT- or Apache-2.0/MIT-dual-licensed (we elect MIT where dual).
Primary crates (see the core's `Cargo.lock` for the complete, pinned set including
transitive dependencies):

| Crate (family) | Purpose | License |
| --- | --- | --- |
| `aes-gcm`, `aead`, `ctr`, `ghash`, `polyval`, `universal-hash`, `cipher`, `aes` | AEAD / AES-GCM | Apache-2.0 OR MIT |
| `hkdf`, `hmac`, `pbkdf2`, `sha2`, `digest`, `crypto-common` | KDF / hashing | Apache-2.0 OR MIT |
| `zeroize`, `subtle` | constant-time / secret hygiene | Apache-2.0 OR MIT |
| `regex`, `regex-automata`, `regex-syntax`, `aho-corasick`, `memchr` | secret detection | Apache-2.0 OR MIT |
| `uuid` | identifiers | Apache-2.0 OR MIT |
| `uniffi` (and `uniffi_*`) | Swift FFI bindings | MPL-2.0 |
| `serde`, `serde_json` | (de)serialization | Apache-2.0 OR MIT |

> `uniffi` is **MPL-2.0** (file-level copyleft). ClipySi links it without modifying
> its source; MPL-2.0 obligations attach to modified MPL files only, of which there
> are none here. Build-time-only crates (e.g. `clap`, `cargo_metadata`, `askama`,
> `uniffi_bindgen`) are not shipped in the released binary.

For the authoritative, fully enumerated list (including every transitive crate and
exact versions), see the core repository's
[`Cargo.lock`](https://github.com/ClipySi/clipy-si-core/blob/main/Cargo.lock) (the core
is open source), or regenerate as noted at the top of this file.

---

## Migration tool (`tools/clipy-realm-export`)

`tools/clipy-realm-export` is a standalone, build-time-only command-line tool that
exports a legacy Clipy (Realm) database to JSON for import into ClipySi. It is **not
shipped inside `ClipySi.app`** and links no part of the released app. Its Swift
Package dependencies (`tools/clipy-realm-export/Package.resolved`) are:

| Package | Version | License | Source |
| --- | --- | --- | --- |
| realm-swift (RealmSwift) | 10.7.2 | Apache-2.0 | https://github.com/realm/realm-swift |
| realm-core | 10.5.5 | Apache-2.0 | https://github.com/realm/realm-core |

Apache-2.0 requires retaining the upstream copyright, license, and NOTICE; see the
linked repositories for the full text. These are vendored only to build the
migration tool and never become part of the released app binary.
