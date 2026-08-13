//
//  HistoryManagerTests.swift
//  ClipyTests
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct HistoryManagerTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x6D, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func sealedClip(title: String,
                            createdAt: Date = Make.epoch,
                            isPinned: Bool = false,
                            sourceBundle: String? = nil,
                            primaryType: String = "public.utf8-plain-text") throws -> Clip {
        var clip = Make.clip(createdAt: createdAt, isPinned: isPinned)
        clip.titleCipher = try cipher.seal(Data(title.utf8))
        clip.primaryType = primaryType
        clip.sourceBundle = sourceBundle
        return clip
    }

    @Test func clipDisplayBuilderDecryptsTitles() throws {
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let clip = try sealedClip(title: "history row")
            let display = ClipDisplayBuilder().display(of: clip)
            #expect(display.title == "history row")
            #expect(display.decryptFailed == false)
            #expect(display.primaryType == "public.utf8-plain-text")
        }
    }

    @Test func historyRowCarriesDisplayMetadataWithoutMutatingClip() throws {
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let createdAt = Make.epoch.addingTimeInterval(120)
            let clip = try sealedClip(
                title: "row title",
                createdAt: createdAt,
                isPinned: true,
                sourceBundle: "com.example.Writer"
            )

            let display = ClipDisplayBuilder().display(of: clip)
            let row = HistoryClipRow(clip: clip, display: display)

            #expect(row.id == clip.id)
            #expect(row.preview == "row title")
            #expect(row.createdAt == createdAt)
            #expect(row.sourceBundleDisplay == "com.example.Writer")
            #expect(row.typeDisplay == "Text")
            #expect(row.pinnedDisplay == "Pinned")
            #expect(row.decryptFailed == false)
            #expect(row.canCopy)
        }
    }

    @Test func historyRowUsesPlaceholderForUndecryptableClip() {
        withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let clip = Make.clip()
            let display = ClipDisplayBuilder().display(of: clip)
            let row = HistoryClipRow(clip: clip, display: display)

            #expect(!row.preview.isEmpty)
            #expect(row.decryptFailed == true)
            #expect(row.canCopy == false)
        }
    }

    @Test func imageClipUsesPlaceholderPreviewAndTypeLabel() throws {
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let clip = try sealedClip(title: "ignored preview",
                                      primaryType: NSPasteboard.PasteboardType.tiff.rawValue)
            let row = HistoryClipRow(clip: clip, display: ClipDisplayBuilder().display(of: clip))
            #expect(row.preview == "(Image)")
            #expect(row.typeDisplay == "Image")
            #expect(row.decryptFailed == false)
        }
    }

    // MARK: - Tombstone exclusion (the P0-C contract, carried into the P5 read path)

    /// The manager's base request fixes `deletedAt IS NULL` inside `managerBase` — every page,
    /// count, facet, and scan-walk read goes through it, so the P0-C leak class (an explicit
    /// load dropping the filter) has no code path left. Soft-deleted rows (content wiped →
    /// undecryptable) must never surface as ghost rows.
    @Test func managerPagesExcludeTombstones() throws {
        let database = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Make.epoch)
        } operation: {
            let repo = ClipRepository()
            for index in 0..<10 {
                try repo.add(Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index))))
            }
            // Soft-delete the 3 NEWEST rows — a leaked filter would rank them at the head.
            for clip in try repo.clips().prefix(3) {
                try repo.delete(id: clip.id, soft: true)
            }

            let data = try repo.managerPage(filter: .none, sort: .newestFirst, after: nil,
                                            limit: 100, options: .count)
            // Count-shaped so a failure message carries only integers, never a [Clip] dump (§3.2).
            let ghostRows = data.page.count { $0.deletedAt != nil }
            #expect(data.page.count == 7)
            #expect(data.filteredCount == 7)
            #expect(ghostRows == 0)
        }
    }

    /// Tombstones must not consume page slots either: with exactly one page of live rows plus
    /// NEWER tombstones, the page serves every live row and no has-more sentinel survives (a
    /// leaked filter would rank the tombstones first AND push live rows past the LIMIT).
    @Test func tombstonesConsumeNoPageSlotsAndTripNoSentinel() throws {
        let database = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let pageSize = 50
            try database.write { db in
                for index in 0..<pageSize {
                    let clip = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index)))
                    try Clip.insert { clip }.execute(db)
                }
                for index in 0..<60 {
                    var dead = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(pageSize + index)))
                    dead.deletedAt = Make.epoch
                    dead.titleCipher = Data()
                    try Clip.insert { dead }.execute(db)
                }
            }

            let repo = ClipRepository()
            let data = try repo.managerPage(filter: .none, sort: .newestFirst, after: nil,
                                            limit: pageSize + 1, options: [.count, .facets])
            let ghostRows = data.page.count { $0.deletedAt != nil }
            #expect(data.page.count == pageSize, "all live rows fit; no sentinel row → no next page")
            #expect(ghostRows == 0)
            // Facets come from the live set only — the tombstones' type must not add a facet.
            #expect(data.typeRawValues?.count == 1)
        }
    }

    // MARK: - Preview truncation (M-UI.11 P5)

    /// `preview` is display-only and capped; search runs on the FULL `searchableTitle`
    /// (HistoryManagerScanTests pins the matching side of this contract).
    @Test func previewIsCappedButSearchableTitleIsNot() throws {
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let longTitle = String(repeating: "a", count: 900) + " needle"
            let clip = try sealedClip(title: longTitle)
            let display = ClipDisplayBuilder().display(of: clip)
            let row = HistoryClipRow(clip: clip, display: display)
            #expect(row.preview.count == HistoryClipRow.previewDisplayCap)
            #expect(HistoryClipRow.searchableTitle(for: display).count == longTitle.count)
        }
    }

    @Test func pdfAndFileClipsGetTypeLabelsAndPlaceholders() throws {
        try withDependencies {
            $0.historyCipher = cipher
        } operation: {
            let pdf = try sealedClip(title: "ignored", primaryType: NSPasteboard.PasteboardType.pdf.rawValue)
            let pdfRow = HistoryClipRow(clip: pdf, display: ClipDisplayBuilder().display(of: pdf))
            #expect(pdfRow.preview == "(PDF)")
            #expect(pdfRow.typeDisplay == "PDF")

            let file = try sealedClip(title: "ignored", primaryType: NSPasteboard.PasteboardType.fileURL.rawValue)
            let fileRow = HistoryClipRow(clip: file, display: ClipDisplayBuilder().display(of: file))
            #expect(fileRow.preview == "(Filenames)")
            #expect(fileRow.typeDisplay == "File")
        }
    }
}
