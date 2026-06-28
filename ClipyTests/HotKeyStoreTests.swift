//
//  HotKeyStoreTests.swift
//  ClipyTests
//
//  The hotkey persistence layer: default combos (matching the original's ints), round-trip through
//  UserDefaults under the verbatim `kCPYHotKey*` keys, true-nil semantics (absence = unbound), and
//  once-only first-run seeding (design §6 delta 13). The Magnet registration itself
//  (HotKeyService) touches the global HotKeyCenter / Carbon and is run-app verified, not unit-tested.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct HotKeyStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClipySiHotKey-\(UUID().uuidString)")!
    }

    @Test func defaultCombosMatchOriginal() {
        #expect(KeyComboValue.mainMenu == KeyComboValue(keyCode: 9, carbonModifiers: 768))  // ⌘⇧V
        #expect(KeyComboValue.history == KeyComboValue(keyCode: 9, carbonModifiers: 4352))   // ⌃⌘V
        #expect(KeyComboValue.snippet == KeyComboValue(keyCode: 11, carbonModifiers: 768))   // ⌘⇧B
    }

    @Test func storesUnderOriginalKeys() {
        #expect(HotKeyType.mainMenu.defaultsKey == "kCPYHotKeyMainKeyCombo")
        #expect(HotKeyType.history.defaultsKey == "kCPYHotKeyHistoryKeyCombo")
        #expect(HotKeyType.snippet.defaultsKey == "kCPYHotKeySnippetKeyCombo")
        #expect(HotKeyType.clearHistory.defaultsKey == "kCPYClearHistoryKeyCombo")
    }

    @Test func clearHistoryShipsUnbound() {
        // The 4th hotkey has no factory default (original `clearHistoryKeyCombo: KeyCombo?` = nil).
        #expect(HotKeyType.clearHistory.defaultCombo == nil)
        #expect(HotKeyType.mainMenu.defaultCombo == .mainMenu)
    }

    @Test func returnsNilWhenUnset() {
        // True-nil: an unseeded store has no combos (absence = unbound), not read-time defaults.
        let store = HotKeyStore(defaults: freshDefaults())
        for type in HotKeyType.allCases {
            #expect(store.combo(for: type) == nil)
        }
    }

    @Test func roundTripsACustomCombo() {
        let store = HotKeyStore(defaults: freshDefaults())
        let custom = KeyComboValue(keyCode: 40, carbonModifiers: 256)
        store.setCombo(custom, for: .history)
        #expect(store.combo(for: .history) == custom)
        #expect(store.combo(for: .mainMenu) == nil) // others untouched → still unbound
    }

    @Test func clearComboRemovesBinding() {
        let store = HotKeyStore(defaults: freshDefaults())
        store.setCombo(.mainMenu, for: .mainMenu)
        store.clearCombo(for: .mainMenu)
        #expect(store.combo(for: .mainMenu) == nil)
    }

    @Test func returnsNilOnCorruptData() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: HotKeyType.mainMenu.defaultsKey)
        #expect(HotKeyStore(defaults: defaults).combo(for: .mainMenu) == nil)
    }

    @Test func seedingWritesDefaultsOnce() {
        let store = HotKeyStore(defaults: freshDefaults())
        store.seedDefaultsIfNeeded()
        #expect(store.combo(for: .mainMenu) == .mainMenu)
        #expect(store.combo(for: .history) == .history)
        #expect(store.combo(for: .snippet) == .snippet)
        #expect(store.combo(for: .clearHistory) == nil) // no default → stays unbound
    }

    @Test func seedingDoesNotResurrectAClearedHotkey() {
        // The §6 delta 13 bug guard: clearing a hotkey must persist, not silently re-seed next launch.
        let defaults = freshDefaults()
        let store = HotKeyStore(defaults: defaults)
        store.seedDefaultsIfNeeded()
        store.clearCombo(for: .mainMenu)
        store.seedDefaultsIfNeeded() // simulate next launch
        #expect(store.combo(for: .mainMenu) == nil)
    }
}
