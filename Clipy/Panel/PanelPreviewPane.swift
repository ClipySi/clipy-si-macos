//
//  PanelPreviewPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The side preview pane for the unified panel (formerly a bottom pane; now a fixed-width
//  column beside the list — right by default, Settings-switchable with an edge-flip). For the
//  highlighted row it shows a metadata line (source app · type glyph · relative time), the content
//  body, and a ↵ Paste button pinned at the bottom. SECURITY: it renders `row.title` ONLY — the MASKED `displayTitle` (bullets for a
//  detected secret), never the raw text — and the Paste button routes through the same callback as the
//  list, so the masked-secret AuthGate still applies. NOTE: the source-app label only appears when the copying app declared
//  `org.nspasteboard.source` (often absent); reliable source-app capture + a full multi-line body are the
//  remaining "real S2" work.
//

import AppKit
import SwiftUI

struct PanelPreviewPane: View {
    /// The highlighted row to preview, or nil when nothing is selected.
    let row: PanelRow?
    /// The user-chosen panel accent — tints the source-app dot.
    let accent: Color
    /// Which side of the main column this pane is rendered on — places the separator hairline on
    /// the pane's INNER edge (leading when right of the list, trailing when left).
    var side: PanelPreviewSide = .right
    /// Lazily-resolved payload (image thumbnail / file size) for the previewed row, when applicable.
    /// Nil = not loaded (yet) — textual kinds never need it.
    var content: PanelPreviewContentProvider.Content?
    /// Paste the previewed row. Wired to the same gated paste path the list uses.
    let onPaste: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row, row.isSelectable {
                metadata(row)
                body(row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // The action row sits at the pane's BOTTOM, separated from the metadata line —
                // the 300pt-era single line (app · type · time · button) was cramped once the
                // pane became a tall side column.
                HStack {
                    Spacer()
                    pasteButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // The pane is rendered ONLY while shown (fully hide ⇄ show, no half strip) at its
        // one fixed width; the footer toggle / ⌘P add+remove it and resize the window in step.
        .frame(width: FloatingPanelLayout.previewWidth(expanded: true))
        // The hairline between the pane and the list — on whichever edge touches the list.
        .overlay(HStack { Divider() }, alignment: side == .right ? .leading : .trailing)
    }

    private func metadata(_ row: PanelRow) -> some View {
        HStack(spacing: 5) {
            if let app = appName(row.sourceBundle) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(app).fontWeight(.semibold).foregroundStyle(.primary)
                separator
            }
            Image(systemName: typeGlyph(row)).foregroundStyle(.secondary)
            // The classifier's language label for a code clip ("Swift", "JSON", …).
            if let language = row.codeLanguage {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    // PRIMARY on the tinted capsule (accent-on-tint reads ~2:1
                    // for the lighter palette entries over the material surface).
                    .foregroundStyle(.primary)
            }
            if let relative = relativeTime(row.createdAt) {
                separator
                Text(relative).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary)
    }

    private var pasteButton: some View {
        Button(action: onPaste) {
            HStack(spacing: 4) {
                Image(systemName: "return")
                Text("Paste", comment: "Preview pane button that pastes the highlighted clip")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func body(_ row: PanelRow) -> some View {
        // Per-kind rich rendering. Textual kinds render `row.title` — the masked display
        // string only, never the raw secret (see the file note / §9 guarantee).
        PanelPreviewRichBody(row: row, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The leading type glyph (mirrors the list row's mapping).
    private func typeGlyph(_ row: PanelRow) -> String {
        if case .snippet = row.kind { return "note.text" }
        switch row.contentKind {
        case .text: return "text.alignleft"
        case .code: return "curlybraces"
        case .url: return "link"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        case .color: return "eyedropper.halffull"
        }
    }

    /// A localized relative time ("5m ago") for a real capture time; nil for the epoch sentinel (snippets
    /// / synthetic rows that carry no time).
    private func relativeTime(_ date: Date?) -> String? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Resolve a source bundle id to its localized app name, or nil when absent/unresolvable.
    private func appName(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
    }
}
