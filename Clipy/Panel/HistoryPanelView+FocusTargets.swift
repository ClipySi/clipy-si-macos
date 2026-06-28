//
//  HistoryPanelView+FocusTargets.swift
//  ClipySi — Apple Silicon rewrite
//
//  The unified panel's two mid-chain focus targets — the category chips row and the
//  All/History/Snippets scope tabs — split out of HistoryPanelView.swift for the file/type length
//  budget. Each is ONE `.focusable()` target with its own key plumbing; together they form the
//  vertical chain `search ↕ chips (when visible) ↕ scope ↕ list`. Plus the open-time focus reset.
//

import SwiftUI

extension HistoryPanelView {
    /// Every open starts on the list (the open contract) — called from the root's
    /// `onChange(of: model.openToken)`. It must hang off the always-present ROOT, not the list:
    /// `reset()` clears the query/category/filter bar in the SAME transaction that bumps the
    /// token, so a panel hidden on an empty state re-inserts the list in that very transaction
    /// and a list-side `onChange` never fires (onChange is silent for the value present at view
    /// insertion). A stale `.search` focus then survived the reopen — the field re-claimed first
    /// responder and digit keys typed into the query instead of pasting (adversarial review).
    /// The deferred re-assert mirrors the old list-side one: the token bumps before the panel
    /// becomes key (the open race). An open with nothing selectable homes to the always-present
    /// scope tabs instead of stranding focus on an unmounted list.
    func focusOnOpen() {
        guard model.firstSelectableVisibleID != nil else { return focusScope() }
        focus = .list
        Task { @MainActor in focus = .list }
    }

    /// The category chips row with its keyboard plumbing (mirrors `scopeTabs`): slotted between
    /// the search field and the scope tabs while visible. `←`/`→` switch the category (wrapping),
    /// `↑` returns to search, `↓`/Return drop to the scope tabs.
    var categoryChips: some View {
        PanelCategoryChips(category: model.category,
                           counts: model.categoryCounts,
                           accent: accent,
                           barFocused: focus == .chips) { category in
            model.setCategory(category)
            focus = .chips
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .chips)
        .accessibilityLabel(Text("Filter by type", comment: "Accessibility label for the category filter chips"))
        // The GLOBAL ⌘-shortcuts keep their meaning here (⌘←/⌘→ scope, ⌘↓ list, ⌘1-3 scope —
        // review: the chips must not hijack them into category changes); bare arrows are the
        // row's own: ←/→ category (wrapping), ↑ search, ↓/Return scope tabs.
        .onKeyPress(keys: [.leftArrow]) { press in
            if press.modifiers.contains(.command) { cycleScope(-1) } else { cycleCategory(-1) }
            return .handled
        }
        .onKeyPress(keys: [.rightArrow]) { press in
            if press.modifiers.contains(.command) { cycleScope(1) } else { cycleCategory(1) }
            return .handled
        }
        .onKeyPress(keys: [.upArrow]) { _ in focusSearch(); return .handled } // ⌘↑ = bare ↑ here
        .onKeyPress(keys: [.downArrow]) { press in
            if press.modifiers.contains(.command) { focusList() } else { focusScope() }
            return .handled
        }
        .onKeyPress(.return) { focusScope(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onKeyPress(keys: ["m"]) { handleManagementKey($0) }
        .onKeyPress(keys: ["p"]) { handlePreviewKey($0) }
        .onKeyPress(keys: ["f"]) { handleFilterKey($0) }
        .onKeyPress(keys: ["1", "2", "3"]) { handleScopeKey($0) }
    }

    /// Step the category chip by `offset` (wrapping through all seven chips). The chips' `←`/`→`.
    private func cycleCategory(_ offset: Int) {
        let categories = PanelCategory.allCases
        let index = categories.firstIndex(of: model.category) ?? 0
        model.setCategory(categories[(index + offset + categories.count) % categories.count])
    }

    /// The All / History / Snippets scope selector (extracted to `PanelScopeTabs` for size/clarity).
    /// This view applies the keyboard plumbing: `↓` from the search field (or the chips row) lands
    /// here, then `←`/`→` cycle scopes, `↑` returns up the chain, `↓`/Return drop into the list.
    /// Tab taps route through `setScope` (re-bases paging like ⌘1/2/3) and pull focus onto the tabs.
    var scopeTabs: some View {
        PanelScopeTabs(scope: model.scope,
                       allCount: model.allCount,
                       historyCount: model.historyCount,
                       snippetCount: model.snippetCount,
                       accent: accent,
                       barFocused: focus == .scope) { scope in
            model.setScope(scope)
            focus = .scope
        }
        .padding(.horizontal, 8)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .scope)
        .accessibilityLabel(Text("Scope", comment: "Accessibility label for the unified panel scope selector"))
        // On the tabs: ←/→ cycle scope (⌘ or not), ↑ → chips when visible else search — but the
        // GLOBAL ⌘↑ still jumps straight to search (review: it must work "from anywhere") —
        // ↓/Return → list, Esc dismisses, ⌘M manages, ⌘1-3 switch scope.
        .onKeyPress(keys: [.leftArrow]) { _ in cycleScope(-1); return .handled }
        .onKeyPress(keys: [.rightArrow]) { _ in cycleScope(1); return .handled }
        .onKeyPress(keys: [.upArrow]) { press in
            if !press.modifiers.contains(.command), model.showsFilterBar { focusChips() } else { focusSearch() }
            return .handled
        }
        .onKeyPress(keys: [.downArrow]) { _ in focusList(); return .handled }
        .onKeyPress(.return) { focusList(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onKeyPress(keys: ["m"]) { handleManagementKey($0) }
        .onKeyPress(keys: ["p"]) { handlePreviewKey($0) }
        .onKeyPress(keys: ["f"]) { handleFilterKey($0) }
        .onKeyPress(keys: ["1", "2", "3"]) { handleScopeKey($0) }
    }
}
