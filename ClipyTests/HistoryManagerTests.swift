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
