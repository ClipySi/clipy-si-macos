//
//  HistoryPanelRowView.swift
//  ClipySi — Apple Silicon rewrite
//
//  One row of the unified FloatingPanel list, rendered by kind. Split out of HistoryPanelView so that
//  view stays within its size budget. Display-only — selection/paste live in HistoryPanelView and the
//  ClipSelectionCoordinator.
//

import SwiftUI

/// One unified-panel row, rendered by kind: a history clip (optionally "N." numbered; with a
/// content-kind glyph; dimmed when it can't be decrypted), a snippet (numbered + a `note.text` glyph that
/// sets it apart from a clip), or a non-selectable folder header (bold + dimmed + a `folder` glyph; never
/// numbered).
struct HistoryPanelRowView: View {
    let row: PanelRow
    let number: Int?
    /// Whether this row is the highlighted one — flips text to white (it sits on the violet selection
    /// fill drawn behind it by `HistoryPanelView`) and shows the trailing "↵" paste hint.
    var isSelected: Bool = false

    /// Primary text colour: white on the violet selection, dimmed for an undecryptable clip, else primary.
    private var primaryForeground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(PanelStyle.selectedForeground) }
        return row.decryptFailed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
    /// Secondary text colour (number, glyph): dimmed white on selection, else secondary.
    private var secondaryForeground: AnyShapeStyle {
        isSelected ? AnyShapeStyle(PanelStyle.selectedSecondaryForeground) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        switch row.kind {
        case .folderHeader: folderHeader
        case .snippet: snippetRow
        case .clip: clipRow
        }
    }

    private var clipRow: some View {
        HStack(spacing: 6) {
            numberLabel
            Image(systemName: glyph(for: row.contentKind))
                .font(.caption)
                .foregroundStyle(secondaryForeground)
                .frame(width: 15)
            Text(row.title.isEmpty ? " " : row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(primaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            pasteHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    private var snippetRow: some View {
        HStack(spacing: 6) {
            numberLabel
            Image(systemName: "note.text").font(.caption).foregroundStyle(secondaryForeground).frame(width: 15)
            Text(row.title.isEmpty ? " " : row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(primaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            pasteHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    private var folderHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.caption2)
            Text(row.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// The leading number for a numbered row (matches the digit that pastes it) — right-aligned in a fixed
    /// column (no trailing period) so 1–9 and 10 line up and the glyphs start at the same x. Coloured to
    /// fit the selection state; absent when numbering is off or past the first ten rows.
    @ViewBuilder private var numberLabel: some View {
        if let number {
            Text(verbatim: "\(number)")
                .monospacedDigit()
                .foregroundStyle(secondaryForeground)
                .frame(width: 18, alignment: .trailing)
        }
    }

    /// The trailing "↵" pill on the selected row — Return pastes the highlighted row. (⌘+digit is the
    /// scope switch, so the per-row paste affordance is Return / the bare digit, not ⌘N.)
    @ViewBuilder private var pasteHint: some View {
        if isSelected {
            Text(verbatim: "↵")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PanelStyle.selectedForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.22)))
                .accessibilityHidden(true)
        }
    }

    /// The leading SF Symbol for a clip's coarse content type. Display-only — the row's paste
    /// path is unaffected. `.text` is the catch-all (incl. anything that would have been a "command").
    private func glyph(for kind: PanelRow.ContentKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .code: return "curlybraces"
        case .url: return "link"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        case .color: return "eyedropper.halffull"
        }
    }
}
