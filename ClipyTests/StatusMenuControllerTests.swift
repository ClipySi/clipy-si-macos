//
//  StatusMenuControllerTests.swift
//  ClipyTests
//
//  The controller builds NO NSMenu — the status item and every hotkey open the unified
//  FloatingPanel, so the only behavior left here is the Clear-History confirm flow (reachable from the
//  `.clearHistory` hotkey and the panel's management overlay). These run headlessly with an in-memory DB
//  + fixed cipher. The NSAlert-shown branch needs a modal, so it is run-app verified; here we cover the
//  suppressed-alert fast path and the bare `performClearHistory`. The snippet/management rendering tests
//  were retired with the menu; the panel's combined rows/management are covered by PanelSearchTests /
//  ClipSelectionCoordinatorTests / PanelManagementTests.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite struct StatusMenuControllerTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults(_ configure: (UserDefaults) -> Void = { _ in }) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiStatusMenu-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        configure(defaults)
        return defaults
    }

    private func sealedClip(title: String, createdAt: Date) throws -> Clip {
        var clip = Make.clip(createdAt: createdAt)
        clip.titleCipher = try cipher.seal(Data(title.utf8))
        return clip
    }

    /// Seeds clips and builds a controller inside the dependency scope.
    private func run(defaults: UserDefaults,
                     seed: (ClipRepository) throws -> Void,
                     body: (StatusMenuController) throws -> Void) throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            try seed(ClipRepository())
            let controller = StatusMenuController(model: MenuModel(settings: AppSettings(defaults: defaults)),
                                                  blobStore: nil)
            try body(controller)
        }
    }

    // MARK: - Clear history

    @Test func performClearHistoryEmptiesTheRepository() throws {
        try run(defaults: freshDefaults(), seed: { repo in
            for index in 0..<3 {
                try repo.add(try sealedClip(title: "c\(index)", createdAt: Make.epoch.addingTimeInterval(Double(index))))
            }
        }, body: { controller in
            try controller.performClearHistory()
            let remaining = try ClipRepository().count()
            #expect(remaining == 0)
        })
    }

    @Test func confirmAndClearHistoryClearsWhenAlertSuppressed() throws {
        // The clear-history hotkey + the panel's Clear button route through `confirmAndClearHistory`
        // (not the bare delete), so they honor the confirm alert. With the alert suppressed there's no
        // modal and it clears — the fast path. (The alert-shown branch needs a modal, so it's run-app.)
        let defaults = freshDefaults { $0.set(false, forKey: DefaultsKeys.showAlertBeforeClearHistory) }
        try run(defaults: defaults, seed: { repo in
            try repo.add(try sealedClip(title: "c0", createdAt: Make.epoch))
        }, body: { controller in
            controller.confirmAndClearHistory()
            let remaining = try ClipRepository().count()
            #expect(remaining == 0)
        })
    }
}
