//
//  HistoryPanelView+Chrome.swift
//  ClipySi — Apple Silicon rewrite
//
//  Small chrome pieces of the unified panel — the side preview pane + footer builders, the
//  snippet-empty CTA, the category-filter toggle, and the management gear — split out of
//  HistoryPanelView.swift for the file/type length budget. Pure presentation over the view's own
//  state; no focus-chain members here.
//

import SwiftUI

extension HistoryPanelView {
    /// The preview pane: fully hide ⇄ show — rendered only while shown (footer toggle /
    /// ⌘P; the controller resizes the window by exactly the pane's width, on the side `content`
    /// resolved into `model.previewSide`). Its Paste button routes through the same gated path as
    /// the list.
    var previewPane: some View {
        PanelPreviewPane(row: model.selectedRow,
                         accent: accent,
                         side: model.previewSide,
                         content: previewProvider.content(for: model.selectedRow)) {
            if let row = model.selectedRow { onSelect(row) }
        }
    }

    /// The bottom bar (pager left + preview toggle and version right), extracted to `PanelFooter`
    /// for the size budget. The toggle is the mouse affordance for the fully-hidden preview pane.
    var footer: some View {
        PanelFooter(pageCount: model.pageCount,
                    currentPage: model.currentPage,
                    isPreviewShown: model.isPreviewExpanded,
                    previewSide: model.previewSide,
                    onPrev: { model.previousPage() },
                    onNext: { model.nextPage() },
                    onTogglePreview: onTogglePreview)
    }

    /// Centred CTA when the Snippets scope is empty: opens the snippet editor (it hides the panel first).
    var snippetEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text.badge.plus")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Button { actions.editSnippets() } label: {
                Label { Text("Add Snippet", comment: "Empty Snippets scope: open the editor to add one") }
                    icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(12)
    }

    /// The category-filter toggle at the search capsule's right edge: shows/hides the chips
    /// row below. Filled + accent-tinted while a non-All chip narrows the list (so an active filter
    /// stays visible with the chips collapsed); hidden in the Snippets scope (no content kinds there).
    /// Mouse-only, like the chips: NOT a focus-chain member.
    @ViewBuilder var filterToggleButton: some View {
        if model.scope != .snippets {
            Button { toggleFilterBar() } label: {
                Image(systemName: model.isCategoryFiltering
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundStyle(model.isCategoryFiltering ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(Text("Filter by type (⌘F)", comment: "Tooltip for the panel's category filter toggle"))
        }
    }

    /// The top-trailing gear that opens the management overlay (Settings/About/…/Quit). Always visible
    /// so the actions are reachable without a snippet present.
    var gearButton: some View {
        Button { openManagement() } label: {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(Text("Manage", comment: "Tooltip for the panel's management gear button"))
    }

    // MARK: - ⌘-letter key handlers (shared by the scope tabs and the list; the search field routes
    // the same letters through `applySearchCommandKey`). Bare letters are ignored so they still
    // type into the search field.

    /// ⌘M opens the management overlay.
    func handleManagementKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        openManagement()
        return .handled
    }

    /// ⌘P toggles the preview pane.
    func handlePreviewKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        onTogglePreview()
        return .handled
    }

    /// Toggle the category filter chips row (the funnel button and ⌘F both route here). No-op in
    /// the Snippets scope, where categories don't apply (the chips row is hidden there). CLOSING
    /// the bar also resets the category to All: the toggle reads as "filtering on/off", so a closed
    /// bar must never keep narrowing the list (and the funnel must not stay tinted — user feedback).
    func toggleFilterBar() {
        guard model.scope != .snippets else { return }
        model.isFilterBarOpen.toggle()
        if !model.isFilterBarOpen {
            model.setCategory(.all)
        }
    }

    func handleFilterKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        toggleFilterBar()
        return .handled
    }

    /// Band auto-fit: report the window-height correction that fits a FULL page
    /// (`itemsPerPage` rows) in the list band — so 10 rows stay visible with the chips row open,
    /// after font-metric changes, etc. Empty states are skipped (no row to measure; the window
    /// keeps its last correction). DEFERRED + COALESCED: the geometry callbacks that call this run
    /// inside the layout pass, where a synchronous window resize nests layout-in-layout and
    /// crashes (user-reported on the chips toggle; reproduced in PanelBandFitTests) — so one
    /// report per run-loop turn fires outside the transaction, computed from the freshest
    /// measurements at fire time (stale per-call deltas could double-apply). A RunLoop perform —
    /// NOT DispatchQueue.main.async — so it also runs under a NESTED run loop (a main-queue async
    /// block can't run until the current main-queue item returns, which made the fit untestable
    /// and would starve it under any modal pump). The controller still resolves each report
    /// absolutely against the current frame, so mid-animation reports converge.
    func proposeListBandFit() {
        guard !isListBandReportScheduled else { return }
        isListBandReportScheduled = true
        RunLoop.main.perform(inModes: [.common]) {
            isListBandReportScheduled = false
            guard model.emptyState == .none,
                  let rowHeight = measuredRowHeight,
                  let bandHeight = measuredListBandHeight else { return }
            let delta = FloatingPanelLayout.listBandDelta(measuredBandHeight: bandHeight,
                                                          rowHeight: rowHeight,
                                                          rowCount: model.itemsPerPage)
            if delta != 0 { onListBandDelta(delta) }
        }
    }
}
