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

    // MARK: - Window query (P0-C hotfix, history-performance plan v2 §6)

    /// `liveWindow` backs BOTH the initial `@FetchAll` and the explicit `loadWindow()` reload. The
    /// reload used to rebuild the window WITHOUT the `deletedAt IS NULL` filter, so tombstones
    /// (content wiped → undecryptable) surfaced as ghost rows after any explicit reload.
    ///
    /// Boundary: these tests pin the SHARED QUERY's semantics; that both view paths consume that
    /// one symbol is a structural fact of HistoryManagerView (the property wrapper and `loadWindow`
    /// both reference `Self.liveWindow`) which a unit test can't drive — `.task`/`@FetchAll` only
    /// run inside a rendered view. Re-introducing an inline query there is what code review must
    /// keep out.
    @Test func liveWindowExcludesTombstonesOnBothLoadPaths() throws {
        let database = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Make.epoch)
        } operation: {
            let repo = ClipRepository()
            for index in 0..<10 {
                try repo.add(Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index))))
            }
            // Soft-delete the 3 NEWEST rows — if the filter leaked they would sit at the window head.
            for clip in try repo.clips().prefix(3) {
                try repo.delete(id: clip.id, soft: true)
            }

            let rows = try database.read { db in try HistoryManagerView.liveWindow.fetchAll(db) }
            // Count-shaped so a failure message carries only integers, never a [Clip] dump (§3.2).
            let ghostRows = rows.count { $0.deletedAt != nil }
            #expect(rows.count == 7)
            #expect(ghostRows == 0)
        }
    }

    /// Tombstones must not consume window slots either: with exactly `windowLimit` live rows plus
    /// newer tombstones, the window returns every live row and no truncation sentinel (the +1 row
    /// that makes `windowTruncated` show its "covers the most recent N" notice).
    @Test func tombstonesConsumeNoWindowSlotsAndTripNoTruncationSentinel() throws {
        let database = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let limit = HistoryManagerView.windowLimit
            try database.write { db in
                for index in 0..<limit {
                    let clip = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index)))
                    try Clip.insert { clip }.execute(db)
                }
                // Newer than every live row: a leaked filter would rank these first AND push
                // live rows past the LIMIT.
                for index in 0..<60 {
                    var dead = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(limit + index)))
                    dead.deletedAt = Make.epoch
                    dead.titleCipher = Data()
                    try Clip.insert { dead }.execute(db)
                }
            }

            let rows = try database.read { db in try HistoryManagerView.liveWindow.fetchAll(db) }
            let ghostRows = rows.count { $0.deletedAt != nil }
            #expect(rows.count == limit, "all live rows fit; no sentinel row → no truncation notice")
            #expect(ghostRows == 0)
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
