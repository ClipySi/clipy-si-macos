//
//  HotKeyValidationTests.swift
//  ClipyTests
//
//  The Shortcuts pane's recordability check (`HotKeyValidation.canRecord`): reject modifier-less
//  combos and combos already bound to another hotkey. Improves on the original's rubber-stamp
//  `canRecordKeyCombo` (design §3.6). The live KeyHolder `RecordView` capture is run-app.
//

import Testing
@testable import Clipy

@Suite struct HotKeyValidationTests {
    private let cmdShiftV = KeyComboValue(keyCode: 9, carbonModifiers: 768)
    private let ctrlCmdV = KeyComboValue(keyCode: 9, carbonModifiers: 4352)

    @Test func acceptsAUniqueComboWithModifiers() {
        #expect(HotKeyValidation.canRecord(cmdShiftV, boundElsewhere: [ctrlCmdV]))
        #expect(HotKeyValidation.canRecord(cmdShiftV, boundElsewhere: []))
    }

    @Test func rejectsModifierlessCombo() {
        let noModifier = KeyComboValue(keyCode: 9, carbonModifiers: 0)
        #expect(HotKeyValidation.canRecord(noModifier, boundElsewhere: []) == false)
    }

    @Test func rejectsAComboBoundToAnotherHotkey() {
        #expect(HotKeyValidation.canRecord(cmdShiftV, boundElsewhere: [cmdShiftV]) == false)
        #expect(HotKeyValidation.canRecord(cmdShiftV, boundElsewhere: [ctrlCmdV, cmdShiftV]) == false)
    }

    @Test func sameKeyDifferentModifiersIsNotAConflict() {
        // Identity is keyCode + modifiers together, so ⌘⇧V and ⌃⌘V don't collide.
        #expect(HotKeyValidation.canRecord(cmdShiftV, boundElsewhere: [ctrlCmdV]))
    }
}
