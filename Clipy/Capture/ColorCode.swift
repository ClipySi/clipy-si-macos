//
//  ColorCode.swift
//  ClipySi — Apple Silicon rewrite
//
//  Detects whether a copied string is a hex color code, so the menu can show a color swatch
//  (original Clipy's `isColorCode` / color-preview feature).
//

import Foundation

enum ColorCode {
    /// `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (case-insensitive).
    static func isColorCode(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return false }
        let hex = trimmed.dropFirst()
        guard [3, 6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy(\.isHexDigit)
    }

    /// RGBA components of a parsed hex color (each 0…1) — the preview swatch's input.
    struct RGBA: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// The RGBA components of a hex color code, or nil when `string` isn't one. `#RGB` expands
    /// each digit (F → FF); a missing alpha pair reads as opaque.
    static func components(_ string: String) -> RGBA? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isColorCode(trimmed) else { return nil }
        var hex = String(trimmed.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        var values: [Double] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            values.append(Double(byte) / 255)
            index = next
        }
        guard values.count >= 3 else { return nil }
        return RGBA(red: values[0], green: values[1], blue: values[2],
                    alpha: values.count == 4 ? values[3] : 1)
    }
}
