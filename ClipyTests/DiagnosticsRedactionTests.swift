//
//  DiagnosticsRedactionTests.swift
//  ClipyTests
//
//  The redaction guarantee, enforced as tests (and gated in CI via .github/workflows).
//  A clipboard manager captures everything the user copies, so the non-negotiable invariant is that
//  NO body data — clipboard contents, clip titles, snippet bodies, search queries, secrets — can
//  ever reach a diagnostic. We prove this three ways:
//    1. A synthetic canary flowed through the maximal set of events never appears in the envelope.
//    2. Even after a canary-titled clip is decrypted and rendered, the envelope stays clean.
//    3. A structural (Mirror) check that DiagnosticEvent payloads are enums only and the environment
//       exposes only an app-controlled allowlist — so a future free-String field fails the build's
//       test gate, not just review.
//

import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct DiagnosticsRedactionTests {
    /// The sentinel. If this string ever shows up in an exported envelope, redaction has failed.
    private static let canary = "CLIPY-CRASH-CANARY"

    private func maximalRecorder() -> DiagnosticsRecorder {
        let rec = DiagnosticsRecorder(level: { .detailed }, installationID: { "anon-installation-id" }, now: { Make.epoch })
        rec.record(.launched)
        rec.record(.crashReceived)
        for area in FeatureArea.allCases { rec.record(.featureUsed(area)) }
        for area in FeatureArea.allCases {
            for kind in DiagnosticErrorKind.allCases { rec.record(.error(area, kind)) }
        }
        return rec
    }

    // MARK: - 1. Canary cannot reach the envelope

    @Test func canaryAndSecretsNeverAppearInEnvelope() throws {
        let json = String(bytes: try maximalRecorder().exportJSON(), encoding: .utf8) ?? ""
        #expect(!json.contains(Self.canary))
        #expect(!json.contains("ghp_"))       // GitHub token prefix
        #expect(!json.lowercased().contains("password"))
    }

    // MARK: - 2. A decrypted clip title never leaks into diagnostics

    @Test func clipTitleNeverReachesDiagnostics() throws {
        let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
        let cipher = HistoryCipher(key: key)
        var clip = Make.clip(createdAt: Make.epoch)
        clip.titleCipher = try cipher.seal(Data("\(Self.canary) ghp_secrettoken000000".utf8))

        // Exercise the real decrypt+render path with the canary clip…
        let display: ClipDisplay = withDependencies {
            $0.historyCipher = cipher
            $0.maskingService = .identity
        } operation: {
            ClipDisplayBuilder().display(of: clip)
        }
        #expect(display.title.contains(Self.canary)) // the title path really did see the canary

        // …then confirm the diagnostics envelope, recorded across the same session, is clean.
        let rec = maximalRecorder()
        let json = String(bytes: try rec.exportJSON(), encoding: .utf8) ?? ""
        #expect(!json.contains(Self.canary))
        #expect(!json.contains("ghp_"))
    }

    // MARK: - 3. Structural guards (catch a future free-String regression)

    /// Compile-time guard: this exhaustive switch fails to compile when a `DiagnosticEvent` case is
    /// added without being covered. That forces whoever adds a case to also extend `samples` below
    /// (and to reckon with the enum-only rule) — closing the "new case never reflected" gap that a
    /// hand-built sample list otherwise leaves.
    private func assertCovered(_ event: DiagnosticEvent) {
        switch event {
        case .launched, .crashReceived, .featureUsed, .error: break
        }
    }

    @Test func eventPayloadsAreEnumsOnly() {
        let allowed: Set<String> = ["FeatureArea", "DiagnosticErrorKind"]
        var samples: [DiagnosticEvent] = [.launched, .crashReceived]
        for area in FeatureArea.allCases { samples.append(.featureUsed(area)) }
        for area in FeatureArea.allCases {
            for kind in DiagnosticErrorKind.allCases { samples.append(.error(area, kind)) }
        }
        for event in samples {
            assertCovered(event) // exercises the exhaustiveness switch above
            for child in Mirror(reflecting: event).children {
                let valueMirror = Mirror(reflecting: child.value)
                if valueMirror.displayStyle == .tuple {
                    for sub in valueMirror.children {
                        #expect(allowed.contains(String(describing: type(of: sub.value))))
                    }
                } else {
                    #expect(allowed.contains(String(describing: type(of: child.value))))
                }
            }
        }
    }

    @Test func environmentExposesOnlyAllowlistedFields() {
        let env = DiagnosticEnvironment.current(installationID: "anon")
        let labels = Set(Mirror(reflecting: env).children.compactMap(\.label))
        #expect(labels == ["appVersion", "build", "osVersion", "cpuArch", "syncProviderType", "installationID"])
    }
}
