//
//  MenuModelTests.swift
//  ClipyTests
//
//  MenuModel reads clips imperatively and decrypts their titles for display. Tests inject an
//  in-memory DB + a fixed cipher (never the real Keychain) and seal titles with that cipher so the
//  decrypt-for-display round-trip, ordering/cap, and the undecryptable-clip fallback are pinned.
//

import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct MenuModelTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults(_ configure: (UserDefaults) -> Void = { _ in }) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiMenu-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        configure(defaults)
        return defaults
    }

    /// A clip whose `titleCipher` is really sealed with the test key (unlike `Make.clip`'s plaintext
    /// stand-in), so `MenuModel` actually decrypts it.
    private func sealedClip(title: String, createdAt: Date) throws -> Clip {
        var clip = Make.clip(createdAt: createdAt)
        clip.titleCipher = try cipher.seal(Data(title.utf8))
        return clip
    }

    private func run(defaults: UserDefaults,
                     seed: (ClipRepository) throws -> Void,
                     body: (MenuModel) throws -> Void) throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let repo = ClipRepository()
            try seed(repo)
            try body(MenuModel(settings: AppSettings(defaults: defaults)))
        }
    }

    @Test func decryptsTitlesForDisplay() throws {
        try run(defaults: freshDefaults(), seed: { repo in
            try repo.add(try sealedClip(title: "hello menu", createdAt: Make.epoch))
        }, body: { model in
            let rows = model.history()
            #expect(rows.count == 1)
            #expect(rows.first?.title == "hello menu")
            #expect(rows.first?.decryptFailed == false)
        })
    }

    @Test func newestFirstByDefault() throws {
        try run(defaults: freshDefaults(), seed: { repo in
            try repo.add(try sealedClip(title: "old", createdAt: Make.epoch))
            try repo.add(try sealedClip(title: "new", createdAt: Make.epoch.addingTimeInterval(60)))
        }, body: { model in
            #expect(model.history().map(\.title) == ["new", "old"])
        })
    }

    @Test func oldestFirstWhenSortedByDateCreated() throws {
        let defaults = freshDefaults { $0.set(false, forKey: DefaultsKeys.historySortNewestFirst) }
        try run(defaults: defaults, seed: { repo in
            try repo.add(try sealedClip(title: "old", createdAt: Make.epoch))
            try repo.add(try sealedClip(title: "new", createdAt: Make.epoch.addingTimeInterval(60)))
        }, body: { model in
            #expect(model.history().map(\.title) == ["old", "new"])
        })
    }

    @Test func capsAtMaxHistorySize() throws {
        let defaults = freshDefaults { $0.set(2, forKey: DefaultsKeys.maxHistorySize) }
        try run(defaults: defaults, seed: { repo in
            for i in 0..<5 {
                try repo.add(try sealedClip(title: "c\(i)", createdAt: Make.epoch.addingTimeInterval(Double(i))))
            }
        }, body: { model in
            let rows = model.history()
            #expect(rows.count == 2)                    // capped to maxHistorySize
            #expect(rows.map(\.title) == ["c4", "c3"])  // newest first
        })
    }

    @Test func negativeMaxHistorySizeClampsWithoutOverfetch() throws {
        // A stored negative cap must NEVER become LIMIT -1 (fetch + decrypt everything). Since
        // M-UI.11 P1, AppSettings normalizes the read into 1...100_000 — the same clamp the
        // Settings UI applies on write — so garbage clamps to the floor of 1, not to empty.
        let defaults = freshDefaults { $0.set(-1, forKey: DefaultsKeys.maxHistorySize) }
        try run(defaults: defaults, seed: { repo in
            for i in 0..<3 {
                try repo.add(try sealedClip(title: "c\(i)", createdAt: Make.epoch.addingTimeInterval(Double(i))))
            }
        }, body: { model in
            let rows = model.history()
            #expect(rows.count == SettingsMapping.minHistorySize)
            #expect(rows.map(\.title) == ["c2"]) // still the newest row, still bounded
        })
    }

    @Test func undecryptableClipDegradesGracefully() throws {
        try run(defaults: freshDefaults(), seed: { repo in
            // `Make.clip` stores plaintext bytes in `titleCipher` — not a valid AES-GCM box for the
            // test key, so opening it throws and the row must fall back to a placeholder.
            try repo.add(Make.clip())
        }, body: { model in
            let row = try #require(model.history().first)
            #expect(row.decryptFailed == true)
            #expect(row.title.isEmpty)
        })
    }
}
