//
//  SyncGateTests.swift
//  ClipyTests
//
//  The pre-sync double gate (push re-evaluates the detector on full text, never trusting
//  stored flags; pull re-evaluates isSensitive) and the shared canonical representation ordering
//  that keeps cross-device syncHash dedupe coherent.
//

import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct SyncGateTests {
    /// Flags any text containing "ghp_" as secret (stand-in for the Rust detector).
    private static let flaggingMasker = MaskingService { MaskingResult(isSecret: $0.contains("ghp_"), display: $0) }

    @Test func pushGateBlocksSecretsAndIneligible() throws {
        withDependencies {
            $0.maskingService = Self.flaggingMasker
        } operation: {
            let gate = SyncGate()
            #expect(gate.allowsPush(syncEligible: true, decryptedText: "plain text"))
            #expect(!gate.allowsPush(syncEligible: true, decryptedText: "token ghp_abc123"),
                    "secret re-detected at push regardless of stored flags")
            #expect(!gate.allowsPush(syncEligible: false, decryptedText: "plain text"),
                    "syncEligible=false always excluded")
            #expect(gate.allowsPush(syncEligible: true, decryptedText: "[TIFF]"),
                    "non-text placeholder titles pass")
        }
    }

    @Test func pullSideReevaluatesIsSensitive() throws {
        withDependencies {
            $0.maskingService = Self.flaggingMasker
        } operation: {
            let gate = SyncGate()
            #expect(gate.isSensitiveOnApply(decryptedTitle: "ghp_pulled") == true,
                    "a secret pushed by an old/compromised device is re-flagged on apply")
            #expect(gate.isSensitiveOnApply(decryptedTitle: "hello") == false)
        }
    }

    @Test func passphraseStrengthAndCloudHints() {
        #expect(PassphraseStrength.score("") == 0)
        #expect(PassphraseStrength.score("short") < 2, "below the 12-char floor stays weak")
        #expect(PassphraseStrength.score("twelvechars!") >= 2)
        #expect(PassphraseStrength.score("Correct-Horse-Battery-9") == 4)

        #expect(SyncFolderHints.looksCloudSynced("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/V"))
        #expect(SyncFolderHints.looksCloudSynced("/Users/x/Dropbox/vault"))
        #expect(!SyncFolderHints.looksCloudSynced("/Volumes/NAS/clipy-vault"))
    }

    @Test func canonicalOrderingIsCapturePriorityThenDeterministic() {
        let tiff = (typeID: "public.tiff", data: Data([1]))
        let string = (typeID: "public.utf8-plain-text", data: Data([2]))
        let rtf = (typeID: "public.rtf", data: Data([3]))
        let unknownB = (typeID: "zz.unknown.b", data: Data([4]))
        let unknownA = (typeID: "zz.unknown.a", data: Data([5]))

        let sorted = CanonicalPayload.sortedForHashing([tiff, unknownB, string, unknownA, rtf])
        #expect(sorted.map(\.typeID) == [
            "public.utf8-plain-text", "public.rtf", "public.tiff", "zz.unknown.a", "zz.unknown.b"
        ])

        // The sorted order reproduces capture's payload bytes for a multi-rep clip.
        let capturePayload = CanonicalPayload.make([string, rtf, tiff])
        let codecPayload = CanonicalPayload.make(CanonicalPayload.sortedForHashing([tiff, rtf, string]))
        #expect(capturePayload == codecPayload)
    }
}
