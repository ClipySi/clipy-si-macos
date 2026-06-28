//
//  HistoryPanelView.swift
//  ClipySi — Apple Silicon rewrite
//
//  SwiftUI body hosted inside the FloatingPanel: one page of history rows as a single-row-height list
//  (history-panel design §3). A click pastes a row (the proven path — `.onTapGesture` needs no key
//  focus). Keyboard (verified working in a non-activating panel): ↑/↓ move the highlight,
//  Return pastes it, ←/→ flip pages, and 1-9/0 paste the matching row on the page. Esc (handled by the
//  panel) dismisses. In DEBUG it also renders the focus PoC readout (§2.5).
//

import Sharing
import SwiftUI

/// The frontmost-app bundle ids around panel presentation, for the §2.5 focus PoC. `preserved` is the
/// pass condition: the app that was frontmost before is still frontmost after the panel takes key.
struct PanelFocusProbe: Equatable {
    let before: String?
    let after: String?
    var preserved: Bool { before != nil && before == after }
}

private extension View {
    /// The search field's focus treatment: an accent border + a soft accent glow (a touch of blur),
    /// animated in/out. Kept out of `HistoryPanelView` to stay within its size budget.
    func panelSearchFocusRing(focused: Bool, accent: Color) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? AnyShapeStyle(accent.opacity(0.9)) : AnyShapeStyle(.clear), lineWidth: 1))
        .shadow(color: focused ? accent.opacity(0.45) : .clear, radius: 3.5)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct HistoryPanelView: View {
    /// Which subview holds keyboard focus. The panel opens on the `list`. Vertical movement chains
    /// `search ↕ scope ↕ list` — with `chips` slotted between search and scope while the category
    /// filter row is visible — and the GLOBAL `⌘↑`/`⌘↓` jump straight to `search`/`list` from
    /// anywhere while `⌘←`/`⌘→` cycle the scope. Internal (not private), like `focus` and the
    /// focus-movement helpers: the +FocusTargets extension file builds the chips/scope rows.
    enum Field: Hashable { case search, chips, scope, list }

    @Bindable var model: HistoryPanelModel
    /// Invoked when a row is chosen (click / Return / number key). The controller hides + pastes.
    let onSelect: (PanelRow) -> Void
    /// Invoked on `Esc` from the search field, so dismissal works even while the text field is first
    /// responder (the panel's own `cancelOperation` may be consumed by the field editor). Wired to hide().
    let onCancel: () -> Void
    /// The six management actions (gear/⌘M overlay). The controller injects closures that hide the panel
    /// first where needed; empty defaults keep previews/tests inert.
    var actions = PanelActions()
    /// Expand/collapse the preview pane (chevron and ⌘P). The controller flips the model state,
    /// resizes the panel window, and persists the preference; an empty default keeps tests inert.
    var onTogglePreview: () -> Void = {}
    /// Lazy payload loading for the rich preview (image thumbnails / file sizes). The
    /// controller injects the live, blob-store-backed provider; the inert default loads nothing.
    var previewProvider = PanelPreviewContentProvider.inert
    /// Band auto-fit: asks the controller to grow/shrink the WINDOW by `delta` so a full
    /// page of rows fits the list band. Fed by the row/band measurements below via
    /// `proposeListBandFit()` (+Chrome); the empty default keeps previews/tests inert.
    var onListBandDelta: (CGFloat) -> Void = { _ in }

    /// Band auto-fit inputs: one standard row's measured height + the list band's
    /// measured height. Internal, like `focus` — `proposeListBandFit()` lives in the +Chrome file.
    @State var measuredRowHeight: CGFloat?
    @State var measuredListBandHeight: CGFloat?
    /// Coalesces band-fit reports to one per main-queue turn (set inside the geometry callbacks,
    /// cleared when the deferred report fires). The deferral is LOAD-BEARING: the callbacks run
    /// inside the layout pass, and resizing the window from there nests a layout inside a layout —
    /// an immediate crash (reproduced in PanelBandFitTests).
    @State var isListBandReportScheduled = false

    /// The user-chosen panel accent (Settings → General → Appearance), read live from the same store the
    /// pane writes — so changing it there is reflected the next time the panel opens. Unknown/legacy raw
    /// values resolve to the default violet.
    @Shared(.appStorage(DefaultsKeys.panelAccent)) private var panelAccentRaw = PanelAccent.default.rawValue
    // Internal (not private): the +Chrome extension file renders with these too.
    var accent: Color { PanelAccent.resolve(panelAccentRaw).color }

    @FocusState var focus: Field?
    /// Where focus was when the management overlay opened, so closing it returns the caret there (e.g.
    /// back into a half-typed search field) instead of always dropping to the list (review #2).
    @State private var focusBeforeManagement: Field?
    /// Lets the list's ↑/⌘↑ focus the search field directly (synchronous AppKit makeFirstResponder), which
    /// works where the @FocusState→field bridge doesn't in the non-activating panel.
    @State private var searchHandle = SearchFieldHandle()
    /// Whether the search field is the first responder — drives its accent focus ring. Tracked separately
    /// because `.search` is unbound in `@FocusState` (the field is decoupled), so `focus == .search` isn't
    /// a reliable "is the field focused" signal. Set via the field's began/ended callbacks.
    @State private var isSearchFocused = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // While the overlay is up, the list/search/gear are disabled: they can't receive a key
            // (so no paste/scope fires under the overlay) and they yield first responder, so the
            // overlay reliably owns Esc and keyboard nav (review #1 / the focus-race concern).
            content
                .disabled(model.isManagementOpen)
            if model.isManagementOpen {
                ManagementOverlay(
                    actions: actions,
                    historyEmpty: model.historyRows.isEmpty,
                    onClose: closeManagement)
            }
        }
        // Pin the content to the panel's size. Without a floor, `NSHostingController` sizes the panel
        // window to the SwiftUI *fitting* size — and the narrow search field + empty state collapse that
        // to a ~76×160 sliver (the panel "opens" but is too small to see). The min keeps it at the
        // panel's size FOR THE CURRENT PREVIEW STATE (380 hidden / 680 shown wide — a fixed
        // expanded floor would fight the smaller hidden-state window); max-infinity still lets it
        // fill if the (resizable) window grows.
        .frame(minWidth: FloatingPanelLayout.size(previewExpanded: model.isPreviewExpanded).width,
               maxWidth: .infinity,
               minHeight: FloatingPanelLayout.defaultSize.height,
               maxHeight: .infinity,
               alignment: .topLeading)
        // The panel is `.titled + .fullSizeContentView` (rounded corners + shadow) with a hidden,
        // transparent titlebar, so NSHostingController reports the ~28pt titlebar height as a TOP
        // safe-area inset — a dead band above the search field. Extend the content into it so it reaches
        // the very top edge. (Done in SwiftUI, not via `NSHostingController.safeAreaRegions = []`, which
        // aborts at launch on this SDK.) Background dragging is off (movement is grab-bar-only),
        // so overlapping the titlebar drag region is fine.
        .ignoresSafeArea()
        // NO `.defaultFocus($focus, .list)` here on purpose. It quietly *re-grabbed* focus to `.list`
        // whenever a list was present — so `→` from the search field (which sets `focus = .scope`) landed
        // on the list instead of the scope toggle, and *only* worked when the result set was empty (no list
        // to steal it). Initial focus on open is driven instead by the list's `.onAppear` claim + the
        // root-level `openToken` re-assert (below) and the visibleRows-gained recovery; `→`/`↓`/`↑` move
        // focus explicitly. With the default target gone, `focus = .scope` is no longer out-competed.
        //
        // Recover focus if it was genuinely lost (nil) once a list exists again — e.g. opening onto an
        // empty history, then it gaining rows. Never steals focus from an active search session
        // (`isSearchFocused` is the AppKit first-responder truth — `focus == .search` alone can decay,
        // see its declaration) or the management overlay, so typing/overlay nav is undisturbed.
        // And when the LIST disappears under the focus (a zero-match category chip clicked while the
        // list was focused), re-home to the always-present scope tabs so the keyboard
        // (⌘1-3/⌘P/⌘M/arrows) stays alive instead of stranding on nil (review).
        .onChange(of: model.visibleRows.isEmpty) { _, isEmpty in
            guard !model.isManagementOpen else { return }
            if !isEmpty {
                if focus == nil, !isSearchFocused { focus = .list }
            } else if focus == .list || (focus == nil && !isSearchFocused) {
                focusScope()
            }
        }
        // Re-drive focus on every open (the reset() openToken bump) — from the always-present ROOT,
        // NOT the list view, which reset() may re-insert in the very transaction that bumps the
        // token (no onChange fires on insertion — see focusOnOpen for the full story).
        .onChange(of: model.openToken) { focusOnOpen() }
        // When the chips row disappears from under the focus (⌘F off, or the scope switched to
        // Snippets), re-home to the always-present scope tabs instead of stranding on nil.
        .onChange(of: model.showsFilterBar) { _, shown in
            if !shown, focus == .chips, !model.isManagementOpen { focusScope() }
        }
    }

    /// The main column (search/chips/scope/list/footer) with the preview pane BESIDE it on the
    /// resolved side (right by default; Settings + the edge-flip rule pick it — the controller
    /// writes the outcome into `model.previewSide`). The pane was previously below the list.
    private var content: some View {
        HStack(spacing: 0) {
            if model.isPreviewExpanded, model.previewSide == .left { previewPane }
            // FIXED width, not flexible: the pane toggle resizes the WINDOW, and a flexible main
            // column would visibly stretch/compress while the frame changes (user-reported). Both
            // columns being fixed, the toggle only ever adds/removes the pane.
            mainColumn
                .frame(width: FloatingPanelLayout.defaultSize.width)
            if model.isPreviewExpanded, model.previewSide == .right { previewPane }
        }
        // Resolve the newly-highlighted row's payload (debounced in the provider; the open-time and
        // pane-shown requests come from the controller). On the container — NOT the pane — so it stays
        // armed regardless of the pane's presence; a hidden pane loads (decrypts) nothing.
        .onChange(of: model.selection) {
            if model.isPreviewExpanded { previewProvider.request(model.selectedRow) }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The drag grab bar: its own 16pt row ABOVE the search field (outside it), so the
            // capsule never overlaps the field (user feedback on the overlay placement).
            PanelGrabBar()
            topBar
            // Category filter chips: shown while the filter toggle is open, hidden in the
            // Snippets scope. While visible, the row is a full focus-chain member:
            // `search ↕ chips ↕ scope ↕ list`, with ←/→ switching the category.
            if model.showsFilterBar {
                categoryChips
            }
            // The scope tabs are always shown (Snippets reads [0] when empty); they double as the `.scope`
            // focus target for ↓/↑/⌘1-3.
            scopeTabs
            Divider()

            // The list (or an empty state) fills the middle band, pushing the footer + fixed preview to the
            // bottom. The panel height is tuned so a default page leaves minimal slack here.
            listRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Band auto-fit input: the middle band's height under the CURRENT
                // chrome (search/scope/chips/footer) — re-measured whenever any of them change.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    measuredListBandHeight = height
                    proposeListBandFit()
                })

            footer
        }
    }

    @ViewBuilder private var listRegion: some View {
        switch model.emptyState {
        case .none:
            list
        case .searchNoResults(let query):
            PanelEmptyStateView(variant: .noSearchResults(query: query), accent: accent)
        case .categoryNoMatches(let category):
            PanelEmptyStateView(variant: .noCategoryMatches(category), accent: accent) {
                model.setCategory(.all)
            }
        case .snippetsCTA:
            // Snippets scope with nothing in it → an inviting CTA instead of a bare "No snippets".
            snippetEmptyState
        case .noHistory:
            PanelEmptyStateView(variant: .noHistory, accent: accent)
        }
    }

    /// The search field (magnifier + a localized "Search" placeholder inside a rounded filled capsule)
    /// and the management gear on ONE row. The All/History/Snippets scope selector is its own
    /// `scopeTabs` row below this one. `→` at the search caret's end still moves focus to the scope tabs.
    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                // Borderless NSTextField wrapper, DECOUPLED from @FocusState (no `.focused` here — that
                // fight is what made an earlier version un-focusable). IME-safe (a conversion-confirm Return
                // doesn't paste), reliably claims first responder when `focus == .search` so ⌘↑ (and the
                // list's top-row ↑→scope→↑) land here. ↓ leaves to the scope tabs; ←/→ are plain caret moves.
                PanelSearchField(
                    text: $model.searchText,
                    handle: searchHandle,
                    // The ⌘↑ hint (open-to-search shortcut) trails the localized "Search" right in the
                    // placeholder, the way the design mockup shows it. ⌘/↑ are universal glyphs (untranslated).
                    placeholder: String(localized: "Search", comment: "History panel search field placeholder") + "   ⌘↑",
                    isFocused: focus == .search,
                    onFocusBegan: { isSearchFocused = true; if focus != .search { focus = .search } },
                    onFocusEnded: { isSearchFocused = false },
                    onReturn: {
                        guard !model.isManagementOpen else { return true } // no paste under the overlay
                        guard let row = model.selectedRow ?? model.firstSelectableVisibleRow else { return false }
                        onSelect(row)
                        return true
                    },
                    onCancel: { onCancel(); return true },
                    onDown: {
                        // ↓ drops out of the search field to the chips row when it's visible, else
                        // to the scope tabs (always present). ←/→ stay plain caret movement; ↑ = none.
                        if model.showsFilterBar { focusChips() } else { focusScope() }
                        return true
                    },
                    onCommandArrow: handleSearchCommandArrow,
                    onCommandKey: applySearchCommandKey,
                    onCommandReturn: {
                        guard !model.isManagementOpen else { return true } // no paste under the overlay
                        guard let row = model.selectedRow ?? model.firstSelectableVisibleRow else { return false }
                        onSelect(row)
                        return true
                    })
                    .frame(maxWidth: .infinity)
                    // Re-base paging/selection onto the new result set on every edit (§4.1).
                    .onChange(of: model.searchText) { model.searchTextDidChange() }

                filterToggleButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
            // On focus: tint the field's edge with the accent + a soft accent glow (just a touch of blur).
            .panelSearchFocusRing(focused: isSearchFocused, accent: accent)

            gearButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 6) // the 16pt grab-bar row above already provides the top breathing room
        .padding(.bottom, 10)
    }

    /// Open the management overlay, remembering the current focus so closing can restore it.
    /// Internal (not private): the +Chrome extension's gear button routes here.
    func openManagement() {
        focusBeforeManagement = focus
        model.isManagementOpen = true
    }

    /// Close the overlay and return focus to where it was when it opened (search field if that's where
    /// ⌘M/the gear fired), falling back to the list. Wired to the overlay's Esc and scrim-tap.
    private func closeManagement() {
        model.isManagementOpen = false
        focus = focusBeforeManagement ?? .list
    }

    /// `⌘1/⌘2/⌘3` → All/History/Snippets, shared by the search field and the list. Ignored unless ⌘ is
    /// held; the scope tabs are always present now, so no snippet-gating.
    func handleScopeKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        switch press.key.character {
        case "1": model.setScope(.all)
        case "2": model.setScope(.history)
        case "3": model.setScope(.snippets)
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Focus movement (shared by the global ⌘-arrows and the per-target arrows)

    /// Move focus into the search field — a direct, click-like AppKit `makeFirstResponder` (the path that
    /// works in the non-activating panel where the `@FocusState`→field bridge doesn't). `⌘↑` / list-top-`↑`
    /// / scope-`↑`.
    func focusSearch() { searchHandle.focus() }

    /// Move focus into the list, ensuring a row is highlighted. `⌘↓` / scope-`↓`. No-op when there are no
    /// selectable rows (e.g. the empty Snippets scope renders the Add-Snippet CTA, not the list) — so focus
    /// isn't stranded on a list view that isn't on screen.
    func focusList() {
        guard model.firstSelectableVisibleID != nil else { return }
        if model.selection == nil { model.selection = model.firstSelectableVisibleID }
        focus = .list
    }

    /// Move focus onto the scope tabs (always present). Re-assert once on the next runloop so the move
    /// works even when leaving the AppKit-first-responder search field. `search`-`↓` / list-top-`↑`.
    func focusScope() {
        focus = .scope
        Task { @MainActor in focus = .scope }
    }

    /// Move focus onto the category chips row (only called while it is visible). Same next-runloop
    /// re-assert as `focusScope` — `search`-`↓` and scope-`↑` land here when the filter bar is open.
    func focusChips() {
        focus = .chips
        Task { @MainActor in focus = .chips }
    }

    /// Change the scope by `offset` (wrapping). The `⌘←`/`⌘→` global action and the scope tabs' `←`/`→`.
    func cycleScope(_ offset: Int) {
        let scopes = HistoryPanelModel.Scope.allCases
        let index = scopes.firstIndex(of: model.scope) ?? 0
        model.setScope(scopes[(index + offset + scopes.count) % scopes.count])
    }

    /// The global ⌘-arrow shortcuts while the search field is first responder: ⌘↓ → list, ⌘←/⌘→ → scope.
    /// ⌘↑ is "search" (we're already here) so it is left to the field. Returns true to consume.
    /// Swallowed under the management overlay (same residual-first-responder hole as the ⌘ keys).
    private func handleSearchCommandArrow(_ direction: PanelArrowDirection) -> Bool {
        guard !model.isManagementOpen else { return true }
        switch direction {
        case .up: return false // already in the search field
        case .down: focusList(); return true
        case .left: cycleScope(-1); return true
        case .right: cycleScope(1); return true
        }
    }

    /// ⌘1/⌘2/⌘3 (scope) and ⌘M (management) while the search field is first responder — invoked from the
    /// field's `performKeyEquivalent` (SwiftUI `.onKeyPress` is unreliable over an embedded NSTextField).
    /// Returns true to consume the shortcut. Swallowed while the management overlay is up: `.disabled`
    /// doesn't reach the AppKit field editor, so without this guard a residual first responder could
    /// switch scope / resize the panel under the overlay (review).
    private func applySearchCommandKey(_ character: Character) -> Bool {
        guard !model.isManagementOpen else { return true }
        switch character {
        case "1": model.setScope(.all); return true
        case "2": model.setScope(.history); return true
        case "3": model.setScope(.snippets); return true
        case "m", "M": openManagement(); return true
        case "p", "P": onTogglePreview(); return true
        case "f", "F": toggleFilterBar(); return true
        default: return false
        }
    }

    // A custom keyboard-controlled list, NOT `List(selection:)`. The native List's arrow/Return handling
    // was unreliable in the non-activating panel (it would swallow ↑/↓/Return without acting, while only
    // ←/→ reached our handlers), so the list opened "selected but dead". Here a focusable container owns
    // every key explicitly via `.onKeyPress`, and the highlight is drawn from `model.selection` — so
    // Enter/↑/↓/⌘↑ work the instant the panel opens. One page (≤ itemsPerPage rows) fits, so a plain
    // ScrollView + LazyVStack needs no recycling. The list fills the middle band (between the divider and
    // the pager/preview); the panel height is tuned so a default page sits with minimal slack.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: FloatingPanelLayout.listRowSpacing) {
                    ForEach(model.visibleRows) { row in
                        HistoryPanelRowView(row: row,
                                            number: model.displayNumber(for: row),
                                            isSelected: row.id == model.selection)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowHighlight(for: row))
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(row) }
                            .id(row.id)
                            // Band auto-fit input: one STANDARD row's height — folder
                            // headers are shorter, so sample the page's first selectable row only.
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                                guard row.id == model.firstSelectableVisibleRow?.id else { return }
                                measuredRowHeight = height
                                proposeListBandFit()
                            })
                    }
                }
                .padding(.vertical, FloatingPanelLayout.listBandPadding / 2)
            }
            // Keep the highlighted row in view as ↑/↓ move it or a new page loads.
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .focusable()
        .focusEffectDisabled() // the row highlight is the focus cue; no ring around the whole list
        .focused($focus, equals: .list)
        // Claim focus ONLY when nothing holds it: the list is re-inserted whenever an empty state
        // clears (zero-match chip → matching one, search un-narrowing), and an unconditional grab
        // stole the keyboard from the chips row mid-←/→ (user-reported) and from the search field
        // mid-typing (`!isSearchFocused` covers the field even if the unbound `.search` value
        // decays to nil). First open claims here; reopens use the root-level openToken re-assert.
        .onAppear { if focus == nil, !isSearchFocused { focus = .list } }
        // Arrows: ↑ = previous candidate, or up to the scope tabs at the top row; ↓ = next candidate, or
        // onto the next page at the bottom row; ←/→ = page. ⌘+arrow are the GLOBAL shortcuts (⌘↑ search,
        // ⌘↓ list, ⌘←/⌘→ scope). Return pastes; 1-9/0 paste by number.
        .onKeyPress(keys: [.upArrow]) { press in
            if press.modifiers.contains(.command) { focusSearch(); return .handled }     // ⌘↑ global
            if model.selectPrevious() { return .handled }                                 // previous candidate
            focusScope()                                                                  // top row → scope tabs
            return .handled
        }
        .onKeyPress(keys: [.downArrow]) { press in
            if press.modifiers.contains(.command) { focusList(); return .handled }        // ⌘↓ global
            if model.selectionIsAtVisibleBottom, model.currentPage < model.pageCount - 1 {
                model.nextPage()                                                          // bottom row → next page
            } else {
                model.selectNext()                                                        // next candidate
            }
            return .handled
        }
        .onKeyPress(keys: [.leftArrow]) { press in
            if press.modifiers.contains(.command) { cycleScope(-1); return .handled }     // ⌘← scope
            model.previousPage(); return .handled                                          // ← page
        }
        .onKeyPress(keys: [.rightArrow]) { press in
            if press.modifiers.contains(.command) { cycleScope(1); return .handled }      // ⌘→ scope
            model.nextPage(); return .handled                                              // → page
        }
        .onKeyPress(keys: ["m"]) { handleManagementKey($0) }
        .onKeyPress(keys: ["p"]) { handlePreviewKey($0) }
        .onKeyPress(keys: ["f"]) { handleFilterKey($0) }
        .onKeyPress(.return) {
            guard let row = model.selectedRow else { return .ignored }
            onSelect(row)
            return .handled
        }
        // ⌘1/⌘2/⌘3 switch scope — checked before the bare-digit paste so a modified digit never pastes.
        .onKeyPress(keys: ["1", "2", "3"]) { handleScopeKey($0) }
        .onKeyPress(characters: .decimalDigits) { press in
            // Bare-digit paste is tied to the visible numbering: it only fires when numbers are shown, so
            // there is never a hidden shortcut. A ⌘-held digit is a scope switch, not a paste.
            guard !press.modifiers.contains(.command),
                  model.markedWithNumbers, let row = model.row(forNumberKey: press.characters) else {
                return .ignored
            }
            onSelect(row)
            return .handled
        }
    }

    /// The selection highlight behind a row (a solid accent fill under a uniform shade — see
    /// `PanelStyle.selectionShade` — inset so it doesn't touch the panel edges). Only the
    /// currently-selected row is filled; folder headers never match `selection` so they stay clear.
    /// The row view flips its text to white when selected so it reads on the shaded accent.
    private func rowHighlight(for row: PanelRow) -> some View {
        let selected = row.id == model.selection
        return RoundedRectangle(cornerRadius: PanelStyle.selectionCornerRadius)
            .fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.clear))
            .overlay(RoundedRectangle(cornerRadius: PanelStyle.selectionCornerRadius)
                .fill(selected ? AnyShapeStyle(PanelStyle.selectionShade) : AnyShapeStyle(.clear)))
            .padding(.horizontal, 8)
    }

}
