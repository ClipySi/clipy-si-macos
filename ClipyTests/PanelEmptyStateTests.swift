//
//  PanelEmptyStateTests.swift
//  ClipyTests
//
//  `HistoryPanelModel.emptyState`, the single decision behind the panel's empty states:
//  which variant shows when the list region has no rows, and the precedence when several narrows
//  (search query, category chip, scope) are active at once. Synthetic rows only.
//

import Foundation
import Testing
@testable import Clipy

@MainActor
@Suite struct PanelEmptyStateTests {
    private func makeModel(history: [PanelRow] = [], snippets: [PanelRow] = []) -> HistoryPanelModel {
        let model = HistoryPanelModel()
        model.reset(historyRows: history, snippetRows: snippets)
        return model
    }
    private func clip(_ title: String, kind: PanelRow.ContentKind = .text) -> PanelRow {
        .clip(UUID(), title: title, contentKind: kind)
    }

    @Test func rowsVisibleMeansNoEmptyState() {
        let model = makeModel(history: [clip("alpha")])
        #expect(model.emptyState == .none)
    }

    @Test func zeroHistoryShowsTheOnboardingCard() {
        let model = makeModel()
        #expect(model.emptyState == .noHistory)
    }

    @Test func searchWithNoMatchWinsAndCarriesTheTrimmedQuery() {
        let model = makeModel(history: [clip("alpha")])
        model.searchText = "  zzz  "
        model.searchTextDidChange()
        #expect(model.emptyState == .searchNoResults(query: "zzz"))
    }

    @Test func categoryWithNoMatchOffersClearFilter() {
        let model = makeModel(history: [clip("alpha")]) // text only — no images
        model.setCategory(.images)
        #expect(model.emptyState == .categoryNoMatches(.images))
        // The Clear Filter action routes through setCategory(.all) and restores the list.
        model.setCategory(.all)
        #expect(model.emptyState == .none)
    }

    @Test func searchTakesPrecedenceOverTheCategoryChip() {
        // Both narrows active and both empty → the query (the most recent, most specific act) wins.
        let model = makeModel(history: [clip("alpha")])
        model.setCategory(.images)
        model.searchText = "zzz"
        model.searchTextDidChange()
        #expect(model.emptyState == .searchNoResults(query: "zzz"))
    }

    @Test func emptySnippetsScopeShowsTheEditorCTA() {
        let model = makeModel(history: [clip("alpha")]) // no snippets
        model.setScope(.snippets)
        #expect(model.emptyState == .snippetsCTA)
    }

    @Test func emptySnippetsBucketBeatsAnActiveSearch() {
        // setScope keeps the query, so ⌘3 with text in the search field used to show "No results /
        // Try a different search" — dead-end advice when there are zero snippets to find. The CTA
        // (the only inline path to creating a first snippet) must win (adversarial review).
        let model = makeModel(history: [clip("alpha")]) // no snippets
        model.searchText = "zzz"
        model.searchTextDidChange()
        model.setScope(.snippets)
        #expect(model.emptyState == .snippetsCTA)
    }

    @Test func emptyHistoryBeatsTheCategoryChip() {
        // With nothing captured at all, a category chip's "Clear Filter" would only reveal the
        // truthful state anyway — show the onboarding card directly (adversarial review).
        let model = makeModel()
        model.setCategory(.images)
        #expect(model.emptyState == .noHistory)
    }
}
