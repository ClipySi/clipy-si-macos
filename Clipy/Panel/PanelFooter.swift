//
//  PanelFooter.swift
//  ClipySi — Apple Silicon rewrite
//
//  The unified panel's bottom bar: the pager on the left (only when there's more than one
//  page) and the brand + version on the right. Always present so the version reads as a persistent
//  footer. Split out of HistoryPanelView to keep that view within its size budget.
//

import SwiftUI

struct PanelFooter: View {
    let pageCount: Int
    let currentPage: Int
    /// Whether the side preview pane is shown — drives the toggle's icon/tooltip (the
    /// pane is fully hidden when off, so this footer button is the persistent mouse affordance).
    var isPreviewShown = false
    /// Which side the pane opens on — the toggle's glyph mirrors it (right/left half filled).
    var previewSide: PanelPreviewSide = .right
    let onPrev: () -> Void
    let onNext: () -> Void
    /// Show/hide the preview pane (the ⌘P action's mouse twin).
    var onTogglePreview: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if pageCount > 1 {
                chevron("chevron.left", enabled: currentPage > 0, action: onPrev)
                Text(verbatim: "\(currentPage + 1) / \(pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                chevron("chevron.right", enabled: currentPage < pageCount - 1, action: onNext)
            }
            Spacer(minLength: 8)
            previewToggle
            Text(verbatim: Self.versionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(Divider(), alignment: .top)
    }

    /// The preview show/hide toggle: a side-half panel glyph matching the pane's side, prominent
    /// while the pane is shown, dimmed while hidden. Mouse-only (not a focus-chain member); ⌘P is
    /// the keyboard route.
    private var previewToggle: some View {
        Button(action: onTogglePreview) {
            Image(systemName: previewSide == .right
                ? "rectangle.righthalf.inset.filled"
                : "rectangle.lefthalf.inset.filled")
                .font(.caption)
                .foregroundStyle(isPreviewShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPreviewShown
            ? Text("Collapse Preview (⌘P)", comment: "Tooltip for the footer button that hides the preview pane")
            : Text("Expand Preview (⌘P)", comment: "Tooltip for the footer button that shows the preview pane"))
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            .frame(width: 20, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
    }

    /// "ClipySi v1.0.0" — brand + marketing version (no build hash; that lives in About).
    private static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "ClipySi v\(version)"
    }
}
