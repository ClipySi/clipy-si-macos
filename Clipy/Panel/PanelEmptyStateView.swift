//
//  PanelEmptyStateView.swift
//  ClipySi — Apple Silicon rewrite
//
//  The unified panel's empty states, one component with three variants: a friendly
//  "No clips yet" onboarding card when the history is empty, "No results" while a search query
//  matches nothing, and "no items in this category" with a Clear Filter escape hatch while a
//  category chip narrows to zero. (The empty-Snippets CTA stays its own view — it opens the
//  editor.) Pure presentation; the variant decision lives in `HistoryPanelModel.emptyState`.
//

import SwiftUI

struct PanelEmptyStateView: View {
    enum Variant: Equatable {
        case noHistory
        case noSearchResults(query: String)
        case noCategoryMatches(PanelCategory)
    }

    let variant: Variant
    /// The user-chosen panel accent — tints the icon and the Clear Filter button.
    let accent: Color
    /// Clear-filter action for `.noCategoryMatches` (sets the category chip back to All).
    /// Unused by the other variants.
    var onClearFilter: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.light))
                .imageScale(.large)
                .foregroundStyle(accent)
            title
                .font(.headline)
            subtitle
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .noCategoryMatches = variant {
                Button { onClearFilter() } label: {
                    Text("Clear Filter", comment: "Empty filtered panel: reset the category chip to All")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
    }

    private var symbol: String {
        switch variant {
        case .noHistory: return "clipboard"
        case .noSearchResults: return "magnifyingglass"
        case .noCategoryMatches(let category): return category.symbol
        }
    }

    private var title: Text {
        switch variant {
        case .noHistory:
            Text("No clips yet", comment: "Panel empty state title when the clipboard history is empty")
        case .noSearchResults(let query):
            Text("No results for “\(query)”", comment: "Panel empty state title when a search matches nothing")
        case .noCategoryMatches:
            Text("No items in this category", comment: "Panel empty state title when a category chip matches nothing")
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch variant {
        case .noHistory:
            Text("Copy something and it will appear here.",
                 comment: "Panel empty state subtitle when the clipboard history is empty")
        case .noSearchResults:
            Text("Try a different search.",
                 comment: "Panel empty state subtitle when a search matches nothing")
        case .noCategoryMatches:
            EmptyView() // the Clear Filter button below is the guidance
        }
    }
}
