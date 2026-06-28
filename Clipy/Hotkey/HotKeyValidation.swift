//
//  HotKeyValidation.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure validation for a global hotkey the user is about to record in the Shortcuts pane. Improves
//  on the original's rubber-stamp `canRecordKeyCombo` (which always returned `true`): a combo must
//  carry at least one modifier and must not collide with another already-bound hotkey
//  (design §3.6). Kept free of AppKit/KeyHolder so it is unit-testable.
//

import Foundation

enum HotKeyValidation {
    /// Whether `candidate` may be bound: it needs at least one (Carbon) modifier and must differ from
    /// every combo already bound to another hotkey.
    static func canRecord(_ candidate: KeyComboValue, boundElsewhere: [KeyComboValue]) -> Bool {
        guard candidate.carbonModifiers != 0 else { return false }
        return !boundElsewhere.contains(candidate)
    }
}
