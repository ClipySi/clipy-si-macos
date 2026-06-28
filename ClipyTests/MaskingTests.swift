//
//  MaskingTests.swift
//  ClipyTests
//
//  The macOS-side wiring of secret masking. The detection/masking logic itself lives in the
//  Rust core and is pinned by its own KAT (Swift conformance test in the clipy-si-core repository); here we
//  verify the app plumbing: `ClipDisplayBuilder` routes the decrypted title through the injected
//  `MaskingService`, exposes the masked string as `displayTitle` for rendering, and keeps the raw
//  `title` untouched for the (auth-gated) reveal path.
//

import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct MaskingTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x71, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func sealedClip(title: String) throws -> Clip {
        var clip = Make.clip(createdAt: Make.epoch)
        clip.titleCipher = try cipher.seal(Data(title.utf8))
        return clip
    }

    /// A stub that masks anything containing "ghp_" — stands in for the real Rust detector so the
    /// wiring is tested deterministically without depending on detection internals.
    private static let stub = MaskingService { text in
        text.contains("ghp_")
            ? MaskingResult(isSecret: true, display: "••••••")
            : MaskingResult(isSecret: false, display: text)
    }

    @Test func builderMasksDisplayTitleButKeepsRawTitle() throws {
        try withDependencies {
            $0.historyCipher = cipher
            $0.maskingService = Self.stub
        } operation: {
            let display = ClipDisplayBuilder().display(of: try sealedClip(title: "ghp_secrettoken00000"))
            #expect(display.isSecret == true)
            #expect(display.displayTitle == "••••••")        // rendered, masked
            #expect(display.title == "ghp_secrettoken00000") // raw retained for reveal
            #expect(display.decryptFailed == false)
        }
    }

    @Test func builderLeavesOrdinaryTextUnmasked() throws {
        try withDependencies {
            $0.historyCipher = cipher
            $0.maskingService = Self.stub
        } operation: {
            let display = ClipDisplayBuilder().display(of: try sealedClip(title: "buy milk and eggs"))
            #expect(display.isSecret == false)
            #expect(display.displayTitle == "buy milk and eggs")
            #expect(display.title == "buy milk and eggs")
        }
    }

    @Test func identityServiceIsTheTestDefault() throws {
        // With no maskingService injected, the test value is `.identity`: displayTitle == title.
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let display = ClipDisplayBuilder().display(of: try sealedClip(title: "ghp_secrettoken00000"))
            #expect(display.isSecret == false)
            #expect(display.displayTitle == display.title)
        }
    }

    @Test func decryptFailureSkipsMaskingAndIsSafe() throws {
        try withDependencies {
            $0.historyCipher = cipher
            $0.maskingService = Self.stub
        } operation: {
            // Plaintext bytes in titleCipher aren't a valid box for the key → decrypt fails.
            let display = ClipDisplayBuilder().display(of: Make.clip())
            #expect(display.decryptFailed == true)
            #expect(display.title.isEmpty)
            #expect(display.displayTitle.isEmpty)
            #expect(display.isSecret == false)
        }
    }

    // MARK: - AuthGate

    @Test func authGateAllowAuthorizes() async {
        #expect(await AuthGate.allow.authenticate("reveal") == true)
    }

    @Test func authGateForwardsInjectedDecision() async {
        let deny = AuthGate { _ in false }
        #expect(await deny.authenticate("reveal") == false)
    }
}
