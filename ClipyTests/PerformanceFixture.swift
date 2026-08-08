//
//  PerformanceFixture.swift
//  ClipyTests
//
//  Synthetic encrypted history corpora for the M-UI.11 baseline (history-performance plan v2 §P0):
//  a deterministic, seeded set of N live clips plus 10% tombstones, with same-second timestamp
//  collisions and a short / URL / code / secret-shaped / 1 KiB / 10,000-char title mix, each title
//  sealed with the real AES-GCM cipher so decrypt cost in measurements is the production cost.
//
//  Determinism: titles come from a SplitMix64 stream with a fixed seed — every run builds the same
//  corpus, so before/after timings compare like with like. (Row UUIDs stay random; nothing measures
//  or asserts on identity.)
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
@testable import Clipy

/// Deterministic 64-bit stream (SplitMix64). Not cryptographic — fixture-content generation only.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

enum PerfFixture {
    /// Fixed corpus key — distinct from the shared test cipher key so a fixture can never
    /// accidentally decrypt under a suite's default dependencies.
    static let key = SymmetricKey(data: Data(repeating: 0x51, count: 32))
    static var cipher: HistoryCipher { HistoryCipher(key: key) }

    struct Corpus {
        let database: any DatabaseWriter
        let liveCount: Int
        let tombstoneCount: Int
    }

    /// An in-memory production-schema DB with `liveCount` live clips + `liveCount/10` tombstones.
    /// Four rows share each `createdAt` second (the same-second collisions the keyset work must
    /// survive), and tombstones follow the soft-delete contract: `deletedAt` set, `titleCipher`
    /// wiped to empty `Data` — a filter leak would surface them as decryption-failed ghost rows.
    static func makeCorpus(liveCount: Int) throws -> Corpus {
        let database = try TestDatabase.make()
        let cipher = self.cipher
        var rng = SeededGenerator(seed: 0xC11B_0A5E)
        let tombstoneCount = liveCount / 10
        let epoch = Make.epoch
        try database.write { db in
            for index in 0..<liveCount {
                var clip = Clip(
                    id: UUID(),
                    contentHash: "perf-live-\(index)",
                    titleCipher: try cipher.seal(Data(title(at: index, using: &rng).utf8)),
                    primaryType: index % 25 == 3
                        ? NSPasteboard.PasteboardType.tiff.rawValue : "public.utf8-plain-text",
                    createdAt: epoch.addingTimeInterval(TimeInterval(index / 4)),
                    isPinned: false,
                    dataPath: "/nonexistent/perf-live-\(index).data",
                    thumbnailID: nil,
                    sourceBundle: index % 7 == 0 ? "com.example.PerfSource" : nil
                )
                clip.updatedAt = clip.createdAt
                try Clip.insert { clip }.execute(db)
            }
            for index in 0..<tombstoneCount {
                // Interleaved through the live range so a leaked filter would corrupt every page.
                var dead = Clip(
                    id: UUID(),
                    contentHash: "perf-dead-\(index)",
                    titleCipher: Data(),
                    primaryType: "public.utf8-plain-text",
                    createdAt: epoch.addingTimeInterval(TimeInterval((index * 10) / 4)),
                    isPinned: false,
                    dataPath: "/nonexistent/perf-dead-\(index).data",
                    thumbnailID: nil,
                    sourceBundle: nil
                )
                dead.updatedAt = dead.createdAt
                dead.deletedAt = epoch
                try Clip.insert { dead }.execute(db)
            }
        }
        return Corpus(database: database, liveCount: liveCount, tombstoneCount: tombstoneCount)
    }

    // MARK: - Title corpus
    //
    // Mix per 10 rows: 6 short prose, 1 URL, 1 code-shaped (alternating Swift/JSON so the
    // classifier's fast path AND keyword+structure path both run), 1 secret-shaped high-entropy
    // line (real detector work). Every 10th slot alternates ≈1 KiB / 10,000-char prose so long
    // titles hit decrypt, mask, and the classifier's scan cap.

    static func title(at index: Int, using rng: inout SeededGenerator) -> String {
        switch index % 10 {
        case 3:
            return "https://example.com/items/\(index)?ref=\(hexString(8, using: &rng))"
        case 6:
            return index % 20 == 6 ? swiftSnippet(index) : jsonSnippet(index)
        case 8:
            return "export API_TOKEN=\(base62String(43, using: &rng))"
        case 9:
            return prose(characterCount: index % 20 == 9 ? 1_024 : 10_000, using: &rng)
        default:
            return "note \(index): \(prose(characterCount: 24 + Int(rng.next() % 24), using: &rng))"
        }
    }

    private static let words = [
        "meeting", "draft", "invoice", "release", "notes", "review", "agenda",
        "follow", "update", "shipping", "detail", "summary", "window", "panel"
    ]

    private static func prose(characterCount: Int, using rng: inout SeededGenerator) -> String {
        var text = ""
        while text.count < characterCount {
            text += words[Int(rng.next() % UInt64(words.count))] + " "
        }
        return String(text.prefix(characterCount))
    }

    private static func hexString(_ length: Int, using rng: inout SeededGenerator) -> String {
        let digits = "0123456789abcdef"
        return String((0..<length).map { _ in digits.randomElement(using: &rng) ?? "0" })
    }

    private static func base62String(_ length: Int, using rng: inout SeededGenerator) -> String {
        let digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in digits.randomElement(using: &rng) ?? "0" })
    }

    /// Classifies as Swift: ≥2 keyword hits (`func `/`guard `/`let `) + braces, indentation, and a
    /// call-shaped paren for the structure gate.
    private static func swiftSnippet(_ index: Int) -> String {
        """
        func load\(index)(_ id: Int) -> Row? {
            guard let row = cache[id] else { return nil }
            let value = transform(row)
            return value
        }
        """
    }

    /// Hits the classifier's JSON fast path (brace-wrapped, `":` present).
    private static func jsonSnippet(_ index: Int) -> String {
        """
        {"item": \(index), "state": "captured", "pinned": false, "tags": ["perf", "fixture"]}
        """
    }
}
