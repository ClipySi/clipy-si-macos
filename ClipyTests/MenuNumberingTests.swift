//
//  MenuNumberingTests.swift
//  ClipyTests
//
//  Pins the load-bearing menu arithmetic ported from the original `MenuManager` (the numbering
//  start, the optional "N. " prefix, and the first-line + UTF-16 title trim) byte-for-byte against
//  the original. The history-specific helpers were retired with the NSMenu history rendering.
//

import Testing
@testable import Clipy

@Suite struct MenuNumberingTests {

    // MARK: - firstIndex

    @Test func firstIndexStartsAtOneByDefault() {
        #expect(MenuNumbering.firstIndex(startWithZero: false) == 1)
        #expect(MenuNumbering.firstIndex(startWithZero: true) == 0)
    }

    // MARK: - menuItemTitle

    @Test func menuItemTitlePrefixesNumberWhenMarked() {
        #expect(MenuNumbering.menuItemTitle("hello", listNumber: 3, markedWithNumbers: true) == "3. hello")
        #expect(MenuNumbering.menuItemTitle("hello", listNumber: 0, markedWithNumbers: true) == "0. hello")
        #expect(MenuNumbering.menuItemTitle("hello", listNumber: 3, markedWithNumbers: false) == "hello")
    }

    // MARK: - trimTitle

    @Test func trimTitleNilIsEmpty() {
        #expect(MenuNumbering.trimTitle(nil, maxLength: 20) == "")
    }

    @Test func trimTitleStripsSurroundingWhitespace() {
        #expect(MenuNumbering.trimTitle("   hello   ", maxLength: 20) == "hello")
    }

    @Test func trimTitleKeepsOnlyFirstLine() {
        #expect(MenuNumbering.trimTitle("first line\nsecond line", maxLength: 50) == "first line")
        #expect(MenuNumbering.trimTitle("\n\nalpha\nbeta\n\n", maxLength: 50) == "alpha")
    }

    @Test func trimTitleShortStringIsUnchanged() {
        let short = "abc"
        #expect(MenuNumbering.trimTitle(short, maxLength: 20) == short)
    }

    @Test func trimTitleTruncatesWithEllipsis() {
        // 26 chars, cap 10 → keep (10 - 3) = 7 chars + "...".
        #expect(MenuNumbering.trimTitle("abcdefghijklmnopqrstuvwxyz", maxLength: 10) == "abcdefg...")
    }

    @Test func trimTitleFloorsMaxLengthAtEllipsisLength() {
        // cap below shortenSymbol.count (3) is floored to 3 → keep 0 chars + "...".
        #expect(MenuNumbering.trimTitle("abcdef", maxLength: 1) == "...")
    }

    @Test func trimTitleCountsUTF16NotCharacters() {
        // Five emoji = 5 Characters but 10 UTF-16 units. Cap 8 → must trim by UTF-16 count.
        let emoji = String(repeating: "😀", count: 5)
        #expect(emoji.count == 5)
        #expect(emoji.utf16.count == 10)
        let trimmed = MenuNumbering.trimTitle(emoji, maxLength: 8)
        #expect(trimmed.utf16.count == 8)      // (8 - 3) kept + 3 for "..."
        #expect(trimmed.hasSuffix("..."))
    }
}
