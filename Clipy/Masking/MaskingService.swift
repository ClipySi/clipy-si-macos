//
//  MaskingService.swift
//  ClipySi — Apple Silicon rewrite
//
//  The macOS shell's thin entry point to the shared Rust redaction core
//  (`ClipySiCore`, built from the clipy-si-core repository via UniFFI → XCFramework). Detection and
//  masking logic live entirely in Rust so every platform behaves identically; this service
//  just turns a decrypted clip title into a display-safe string per the user's settings.
//
//  Injected as `\.maskingService` (mirroring `\.historyCipher`): the live value calls into
//  ClipySiCore; tests/previews get an identity value so existing menu/history tests see
//  unmasked output. The core is pure — no I/O, no logging — and never sees the plaintext key.
//

import Foundation
import ClipySiCore
import SQLiteData // re-exports swift-dependencies (DependencyKey / DependencyValues)

/// The outcome of evaluating one clip title.
struct MaskingResult: Sendable, Equatable {
    /// A secret was detected (independent of whether masking display is enabled).
    let isSecret: Bool
    /// What to render: bullets/partial when masking is enabled and a secret is present,
    /// otherwise the original text verbatim.
    let display: String
}

struct MaskingService: Sendable {
    /// Evaluate a decrypted clip title. Pure with respect to the input; reads current settings.
    var evaluate: @Sendable (_ text: String) -> MaskingResult
}

extension MaskingService {
    /// Identity: never masks, never flags. Used by tests/previews so display-path tests don't
    /// have to account for redaction.
    static let identity = MaskingService { MaskingResult(isSecret: false, display: $0) }

    /// Live value backed by the Rust core. The entropy thresholds come from the core's
    /// `defaultConfig()` (resolved once); `enabled`/`style` are read from settings per call so a
    /// Privacy-pane toggle takes effect on the next menu open without re-instantiating anything.
    static let live: MaskingService = {
        let base = defaultConfig()
        return MaskingService { text in
            guard !text.isEmpty else { return MaskingResult(isSecret: false, display: text) }
            var config = base
            let settings = AppSettings()
            config.enabled = settings.maskSecretsInMenu
            config.style = maskStyle(from: settings.maskStyleRaw)
            let secret = isSecret(text: text, config: config)
            let display = mask(text: text, config: config)
            return MaskingResult(isSecret: secret, display: display)
        }
    }()

    /// Maps the persisted style string to the core enum. Unknown values fall back to the
    /// safe-default `.full` (hide everything).
    static func maskStyle(from raw: String) -> MaskStyle {
        switch raw {
        case "prefix2": return .prefix2
        case "suffix4": return .suffix4
        default: return .full
        }
    }
}

private enum MaskingServiceKey: DependencyKey {
    static var liveValue: MaskingService { .live }
    static var testValue: MaskingService { .identity }
    static var previewValue: MaskingService { .identity }
}

extension DependencyValues {
    var maskingService: MaskingService {
        get { self[MaskingServiceKey.self] }
        set { self[MaskingServiceKey.self] = newValue }
    }
}
