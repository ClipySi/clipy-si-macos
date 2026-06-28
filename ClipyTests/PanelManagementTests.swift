//
//  PanelManagementTests.swift
//  ClipyTests
//
//  The unified panel's management overlay metadata. The load-bearing invariant is mnemonic
//  uniqueness: each action's single-letter shortcut (E/H/S/A/C/Q) must be distinct, or a key press would
//  be ambiguous. Pure value checks — no window.
//

import Testing
@testable import Clipy

@Suite struct PanelManagementTests {
    @Test func mnemonicsAreUniqueAcrossAllActions() {
        let mnemonics = ManagementAction.allCases.map(\.mnemonic)
        #expect(Set(mnemonics).count == ManagementAction.allCases.count)
    }

    @Test func everyActionHasAGlyphAndAnUppercasedMnemonicLabel() {
        for action in ManagementAction.allCases {
            #expect(!action.glyph.isEmpty)
            #expect(action.mnemonicLabel == String(action.mnemonic).uppercased())
        }
    }

    @Test func expectedActionSetAndMnemonics() {
        // Pin the action set + their letters so a future reorder/rename can't silently drop one or
        // collide a mnemonic (the overlay and the §確定事項 both assume these six).
        let byAction = Dictionary(uniqueKeysWithValues: ManagementAction.allCases.map { ($0, $0.mnemonic) })
        #expect(byAction[.editSnippets] == "e")
        #expect(byAction[.history] == "h")
        #expect(byAction[.settings] == "s")
        #expect(byAction[.about] == "a")
        #expect(byAction[.clearHistory] == "c")
        #expect(byAction[.quit] == "q")
    }
}
