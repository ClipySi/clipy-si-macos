# clipy-realm-export

A standalone, **non-shipped** migration tool that reads the **original Clipy's** clipboard history
(a Realm `default.realm` + the per-clip `.data` archives) and emits the **ClipySi History Manager
JSON** format. This keeps the ClipySi app itself **Realm-free**: you run this tool once, then import
the JSON in the app via **History… → Import…**.

It is intentionally separate from the app (its own SwiftPM package — RealmSwift lives only here, never
in `Clipy.xcodeproj`).

## What it does

- Copies **only** the realm body to a temp dir (0700) and opens **that throwaway copy** (read-write,
  so realm-core can upgrade the old on-disk file format in place) — the original `default.realm` and
  `.data` files are never opened or modified, even if the product Clipy is running.
- Reads each `CPYClip`, loads its `.data` blob, and **securely** decodes it
  (`requiresSecureCoding = true` + an allow-listed shim that reads only `types` / `stringValue`).
- **Text-only**: image / PDF / file / RTF-only clips are skipped (and counted). No clip content is
  ever printed except the JSON you ask for.
- Emits `{ "version": 1, "exportedAt": …, "items": [ { "createdAt", "type", "app", "pinned", "text" } ] }`
  — the exact format ClipySi's importer reads.

## Build & run

```bash
cd tools/clipy-realm-export
swift build -c release
swift run -c release clipy-realm-export --output ~/Desktop/clipy-history.json
```

### Options

| Flag | Default |
| --- | --- |
| `--realm <path>` | `~/Library/Application Support/com.clipy-app.Clipy/default.realm` |
| `--data-dir <path>` | `~/Library/Application Support/Clipy` |
| `--output, -o <path>` | stdout |

Then in **ClipySi**: open the status menu → **History…** → **Import…** → pick the JSON.

## ⚠️ The exported JSON is UNENCRYPTED plain text

It contains your clipboard history in the clear. The tool sets `0600` on `--output` files; delete the
JSON once you've imported it.

## Why RealmSwift 10.7.2 (not the latest)

The original Clipy v1.2.1 wrote its `default.realm` in **Realm file format 9**, which the latest
realm-core (20.x) refuses to open (`UnsupportedFileFormatVersion`). This tool pins **RealmSwift
10.7.2 / realm-core 10.5.5 — the same version Clipy 1.2.2 uses** — which still reads format 9 and
(despite the `std::is_pod` hardening that blocks later 10.x cores) builds cleanly on the macOS 26 SDK.
Verified end-to-end against a real v1.2.1 `default.realm` (30/30 text clips).

## Scope

Text history only (matching the app's text-only import). Snippets already migrate via the app's
**XML import** (Edit Snippets → Import). Images/PDF/files are out of scope by design.
