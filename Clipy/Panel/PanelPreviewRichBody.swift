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
//  Big text/code bodies render in TWO PHASES (M-UI.12): a cheap `placeholderLimit` prefix paints
//  on the selection-change frame, and the full capped body — split/highlighted off the MainActor
//  in `PanelPreviewBody.prepare` — swaps in a beat later. The prepare is debounced ~120ms behind
//  a cancellable sleep, so held-arrow traversal neither lays out nor tokenizes a clip it passed
//  over. At most `PanelPreviewBody.renderLimit` characters ever reach a `Text` — the URL host
//  line included (the "(preview truncated)" note marks the cut); the paste path always delivers
//  the full payload.
//

import SwiftUI

struct PanelPreviewRichBody: View {
    let row: PanelRow
    /// Lazily-resolved payload (image thumbnail / file size) for the row, when applicable.
    let content: PanelPreviewContentProvider.Content?

    /// The async-prepared body (capped text split / highlighted code) keyed by the INPUTS it was
    /// built FROM, computed off the render path (`.task(id:)`). The key is the render-time
    /// guard: @State survives row changes AND body remounts (code→text→code), where a value
    /// without the key could paint the previous row's body for the first frame (review).
    @State private var prepared: PreparedBody?

    private struct PreparedBody: Equatable {
        let key: PreparationKey
        let payload: PanelPreviewBody.Payload
    }

    /// Everything the prepared payload is a function of — NOT just `row.id`: an open-panel
    /// reconcile can keep the same selected id while its title changes, and the model's lazy
    /// classification upgrades a same-id row text→code in place (no remount now that the task
    /// lives on the container). Keying on the title itself subsumes any `updatedAt` revision
    /// check: a revision that changes what this view renders necessarily changes one of these
    /// three fields, and one that doesn't needs no re-prepare (review).
    private struct PreparationKey: Equatable {
        let rowID: RowID
        let title: String
        let kind: PanelRow.ContentKind
        let language: String?
    }

    private var preparationKey: PreparationKey {
        PreparationKey(rowID: row.id, title: row.title, kind: effectiveKind, language: row.codeLanguage)
    }

    var body: some View {
        Group {
            switch effectiveKind {
            case .code: codeBody
            case .url: urlBody
            case .image: imageBody
            case .color: colorBody
            case .pdf, .file: fileBody
            case .text: textBody
            }
        }
        .task(id: preparationKey) {
            let key = preparationKey
            guard PanelPreviewBody.needsPreparation(kind: key.kind, title: key.title) else { return }
            // The cancellation point (review): the detached prepare below runs to completion once
            // spawned, so absorb selection churn HERE — a passed-over row's task dies inside this
            // sleep and never launches a tokenization. Only a row the user rests on pays one.
            try? await Task.sleep(nanoseconds: PanelPreviewBody.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            // Detached: splitting/tokenizing is pure CPU work; keep it off the MainActor render path.
            let payload = await Task.detached(priority: .userInitiated) {
                PanelPreviewBody.prepare(kind: key.kind, title: key.title, languageLabel: key.language)
            }.value
            // A detached task doesn't inherit cancellation: when the selection has already moved
            // on (.task(id:) restarted), drop this result instead of stamping it onto the new row.
            guard !Task.isCancelled, let payload else { return }
            prepared = PreparedBody(key: key, payload: payload)
        }
    }

    /// Snippets and folder rows render as plain text regardless of their (always-.text) kind.
    private var effectiveKind: PanelRow.ContentKind {
        if case .clip = row.kind { return row.contentKind }
        return .text
    }

    /// The prepared payload, ONLY when it was built from exactly this row's current inputs — a
    /// stale value (different row, or a same-id row whose title/kind/language moved on) falls
    /// back to the placeholder instead of painting outdated content.
    private var preparedPayload: PanelPreviewBody.Payload? {
        prepared?.key == preparationKey ? prepared?.payload : nil
    }

    /// Marks the body cap on an over-limit clip. Present from the placeholder frame on (the flag
    /// is limit-independent), so it never flickers when the prepared body lands.
    private var truncationNote: some View {
        Text("(preview truncated)",
             comment: "Note under the preview body when a long clip is cut at the preview limit")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    // MARK: - Text (and snippets): readable typography, first line emphasized

    private var textBody: some View {
        // Short bodies: the placeholder-limit split IS the final content, rendered synchronously
        // (no swap, no flicker). Long bodies: this placeholder paints instantly; the prepared
        // full capped split replaces it when the task lands.
        let text: PanelPreviewBody.TextContent
        if case .text(let ready) = preparedPayload {
            text = ready
        } else {
            text = PanelPreviewBody.textContent(row.title, limit: PanelPreviewBody.placeholderLimit)
        }
        return ScrollView {
            // Reading sizes for the wide side pane (420pt): 15pt semibold first line over a 13pt
            // body — the old 12/11pt callout/subheadline pair was tuned for the short bottom strip.
            VStack(alignment: .leading, spacing: 4) {
                Text(text.firstLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if let rest = text.rest {
                    Text(rest)
                        .font(.body)
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                }
                if PanelPreviewBody.isTruncated(row.title) {
                    truncationNote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
        }
    }

    // MARK: - Code: highlighted block, line-preserving monospace

    private var codeBody: some View {
        let text: AttributedString
        if case .code(let ready) = preparedPayload {
            text = ready
        } else {
            // Plain capped prefix until the highlight lands — the pre-M-UI.12 fallback built an
            // AttributedString of the FULL title here, which was the big-code-clip stall.
            text = AttributedString(String(row.title.prefix(PanelPreviewBody.placeholderLimit)))
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.disabled)
                if PanelPreviewBody.isTruncated(row.title) {
                    truncationNote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - URL: host emphasized, full URL below (never fetched)

    private var urlBody: some View {
        // Same render cap as text/code, applied to BOTH lines — `URL.host()` echoes a multi-KB
        // host verbatim, so the emphasized line needs the cap as much as the full URL below it.
        let url = PanelPreviewBody.urlContent(row.title)
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if let host = url.host {
                    Text(host)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(url.urlText)
                    .font(.body)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                if url.isTruncated {
                    truncationNote
                }
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
