# Security Policy

ClipySi is a clipboard manager. By design it can observe and store **everything you
copy** — including passwords, API keys, OTPs, private keys, and other secrets — so we
treat security reports with high priority.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Instead, use the private channel below:

- **Preferred:** GitHub's [private vulnerability reporting](https://github.com/ClipySi/clipy-si-macos/security/advisories/new)
  (Security → *Report a vulnerability* on the repository). This keeps the report
  confidential until a fix is available.

When reporting, please include where practical:

- A description of the issue and its impact.
- Steps to reproduce or a proof of concept.
- Affected version (see **About ClipySi** for the version/build) and macOS version.
- Any suggested remediation.

Please **do not include real secrets** (real passwords, tokens, private keys) in a
report — use clearly fake placeholder values to demonstrate the issue.

## Scope

Security-sensitive areas of ClipySi include:

- **Capture / ingest** — pasteboard monitoring and privacy-marker handling.
- **Persistence** — at-rest encryption, Keychain key handling, on-disk footprint.
- **Paste** — `CGEvent` keystroke injection and frontmost-app handling.
- **Update** — the Sparkle (EdDSA) auto-update path and appcast feed.
- **Crypto core** — the shared Rust core ([ClipySi/clipy-si-core](https://github.com/ClipySi/clipy-si-core))
  for detection/masking, at-rest crypto primitives, KDF, record/vault formats, and sync
  decisions. Core-specific issues can also be reported privately on that repository;
  either channel is fine — we coordinate fixes across both.

Out of scope: vulnerabilities in third-party dependencies should be reported to
their respective projects (we will still help coordinate where we can).

## Supported versions

ClipySi is distributed via Developer ID direct download + GitHub Releases with
Sparkle auto-updates. Only the **latest released version** receives security fixes.
Please update to the latest release before reporting.

## Disclosure process

1. We acknowledge your report as soon as we can (typically within a few days).
2. We investigate, develop a fix, and validate it.
3. We publish a new release and a GitHub Security Advisory crediting the reporter
   (unless you prefer to remain anonymous).

Thank you for helping keep ClipySi and its users safe.
