//
//  PanelPreviewRichBody.swift
//  ClipySi — Apple Silicon rewrite
//
//  The preview pane's per-kind content body: readable multi-line text (first line
//  emphasized), syntax-highlighted code, host-emphasized URLs (NO network — favicon/title fetch is
//  rejected on privacy grounds), real image thumbnails (lazily decrypted via the provider), a color
//  swatch, and file/PDF metadata. SECURITY: everything textual renders `row.title` — the MASKED
//  display string; a masked-secret row is all bullets, classifies as plain text, and never reaches
//  the provider, so this view can't surface a secret.
//

import SwiftUI

struct PanelPreviewRichBody: View {
    let row: PanelRow
    /// Lazily-resolved payload (image thumbnail / file size) for the row, when applicable.
    let content: PanelPreviewContentProvider.Content?

    /// Highlighted code keyed by the row it was tokenized FROM, computed off the render path
    /// (`.task(id:)`) so a big clip never stalls the panel; plain monospaced text shows until it
    /// lands. The id key is the render-time guard: @State survives row changes AND `codeBody`
    /// remounts (code→text→code), where a value without the key could paint the previous row's
    /// body for the first frame (review).
    @State private var highlighted: HighlightedCode?

    private struct HighlightedCode: Equatable {
        let rowID: RowID
        let text: AttributedString
    }

    var body: some View {
        switch effectiveKind {
        case .code: codeBody
        case .url: urlBody
        case .image: imageBody
        case .color: colorBody
        case .pdf, .file: fileBody
        case .text: textBody
        }
    }

    /// Snippets and folder rows render as plain text regardless of their (always-.text) kind.
    private var effectiveKind: PanelRow.ContentKind {
        if case .clip = row.kind { return row.contentKind }
        return .text
    }

    // MARK: - Text (and snippets): readable typography, first line emphasized

    private var textBody: some View {
        let lines = row.title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return ScrollView {
            // Reading sizes for the wide side pane (420pt): 15pt semibold first line over a 13pt
            // body — the old 12/11pt callout/subheadline pair was tuned for the short bottom strip.
            VStack(alignment: .leading, spacing: 4) {
                Text(lines.first.map(String.init) ?? " ")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if lines.count > 1 {
                    Text(String(lines[1]))
                        .font(.body)
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
        }
    }

    // MARK: - Code: highlighted block, line-preserving monospace

    private var codeBody: some View {
        ScrollView {
            // Render the stored highlight ONLY when it was tokenized from THIS row — a stale value
            // (different row) falls back to plain text instead of painting the wrong clip's body.
            Text(highlighted?.rowID == row.id ? highlighted!.text : AttributedString(row.title))
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
        }
        .task(id: row.id) {
            let source = row.title
            guard let language = CodeClassifier.Language(rawValue: row.codeLanguage ?? "") else { return }
            // Detached: tokenizing is pure CPU work; keep it off the MainActor render path.
            let result = await Task.detached(priority: .userInitiated) {
                CodeHighlighter.highlight(source, language: language)
            }.value
            // A detached task doesn't inherit cancellation: when the selection has already moved
            // on (.task(id:) restarted), drop this result instead of stamping it onto the new row.
            guard !Task.isCancelled else { return }
            highlighted = HighlightedCode(rowID: row.id, text: result)
        }
    }

    // MARK: - URL: host emphasized, full URL below (never fetched)

    private var urlBody: some View {
        let trimmed = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed)?.host()
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if let host {
                    Text(host)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(trimmed)
                    .font(.body)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Image: the decrypted, downsampled thumbnail (provider-gated)

    @ViewBuilder private var imageBody: some View {
        if case let .image(image, meta) = content {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                // The ORIGINAL image's facts (the thumbnail above is downsampled): "1920 × 1080 ·
                // 2.4 MB". Numerals + a formatted byte count — no localizable text.
                if let meta {
                    Text(verbatim: Self.imageMetaLine(meta))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(row.title).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Color: swatch + hex

    private var colorBody: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(swatchColor ?? .clear)
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            Text(row.title.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var swatchColor: Color? {
        guard let parts = ColorCode.components(row.title) else { return nil }
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: parts.alpha)
    }

    // MARK: - File / PDF: big type icon + byte size (ciphertext stat — no decryption)

    private var fileBody: some View {
        HStack(spacing: 12) {
            Image(systemName: effectiveKind == .pdf ? "doc.richtext" : "doc")
                .font(.largeTitle.weight(.light))
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if case .fileInfo(let byteSize) = content, let byteSize {
                    Text(Self.byteFormatter.string(fromByteCount: Int64(byteSize)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// "1920 × 1080 · 2.4 MB" — dimensions only when CGImageSource could read them.
    private static func imageMetaLine(_ meta: PanelPreviewContentProvider.ImageMeta) -> String {
        var parts: [String] = []
        if let width = meta.pixelWidth, let height = meta.pixelHeight {
            parts.append("\(width) × \(height)")
        }
        parts.append(byteFormatter.string(fromByteCount: Int64(meta.byteSize)))
        return parts.joined(separator: " · ")
    }
}
