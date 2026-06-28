# ClipySi Distribution & Privacy Disclosure Matrix

_Last updated: 2026-06-27_

How ClipySi is distributed, and how that maps to per-channel privacy disclosure
obligations. See the full policy in [PRIVACY.md](PRIVACY.md), bundled-dependency
notices in [../THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md), and the
vulnerability-reporting policy in [../SECURITY.md](../SECURITY.md).

## Channels

| Channel | Status | Notes |
| --- | --- | --- |
| **Developer ID direct download + GitHub Releases** | **Live** — v1.0.0 published with an EdDSA-signed Sparkle appcast (`Scripts/release-notarize.sh` pipeline; notarization verified end-to-end on a quarantined download) | The primary (and currently only intended) channel. Signed with a Developer ID certificate, Hardened Runtime, and notarized. **Unsandboxed** — required because Accessibility + `CGEvent` paste injection are incompatible with the App Sandbox. |
| Mac App Store (MAS) | Not pursued | The Sandbox/Accessibility incompatibility makes a clipboard manager a poor MAS fit, and MAS clipboard managers have been rejected under guideline 2.4.5. Choosing direct distribution keeps the privacy surface small. |
| iOS / Android companions | Future (out of scope for v1.0) | If pursued, store distribution would require App Privacy Details / Data safety declarations derived from this matrix. |

## Why unsandboxed + Developer ID

ClipySi injects ⌘V via `CGEvent` and needs the macOS Accessibility trust, which the
App Sandbox forbids. It therefore ships **unsandboxed** under **Developer ID with
Hardened Runtime + notarization**. Entitlements are kept minimal — in fact the
notarized build ships with **no entitlements at all** (the SPM-embedded Sparkle
framework is re-signed with the same team at build time, so even
`com.apple.security.cs.disable-library-validation` is unnecessary). No network
entitlement is used for data collection — the app has no analytics backend.

## Disclosure obligations by channel

| Channel | Disclosure artifact | Required now? |
| --- | --- | --- |
| Developer ID + GitHub Releases | A published privacy policy ([PRIVACY.md](PRIVACY.md)) linked from the app and the download page | **Yes** — done. |
| Mac App Store | App Privacy "nutrition label" (App Privacy Details) | No — only if MAS is ever pursued. |
| Google Play | Data safety section | No — only if an Android companion ships. |

Because the only distribution channel for v1.0 is Developer ID direct, the public
release blockers reduce to: **(1) a published privacy policy, and (2) a redaction
guarantee for diagnostics** (enforced by tests + the `macos-app` CI gate; see
`Scripts/redaction-grep.sh` and `ClipyTests/DiagnosticsRedactionTests.swift`).

## What would change for store distribution

If ClipySi (or a companion) is ever submitted to a store, the App Privacy Details /
Data safety form must be filled in to **match the implementation**:

- **Crash Data / Diagnostic Data:** collected **only with user opt-in**, used for
  app functionality / diagnostics, **not linked to identity** (anonymous
  on-device ID), **not used for tracking**.
- **No other data types** are collected (no contacts, identifiers for advertising,
  usage data beyond opt-in diagnostics, etc.).
- Clipboard contents are **not** collected — this must be stated explicitly.
