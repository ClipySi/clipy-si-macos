//
//  HistoryFilterBar.swift
//  ClipySi — Apple Silicon rewrite
//
//  The History Manager's filter/search row: a text search field plus Type and App dropdowns. Purely
//  a control surface — it mutates bound query state only; `HistoryManagerStore` turns it into SQL
//  narrowing or a progressive search (M-UI.11 P5). The Type/App option lists come from the store's facets.
//

import SwiftUI

struct HistoryFilterBar: View {
    @Binding var searchText: String
    @Binding var typeFilter: String?
    @Binding var appFilter: String?
    let availableTypes: [String]
    let availableApps: [String]
    let showClear: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            searchField
            Spacer(minLength: 12)
            typePicker
            appPicker
            if showClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear search and filters")
                .accessibilityLabel(Text("Clear search and filters"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .frame(minWidth: 180, maxWidth: 260)
    }

    private var typePicker: some View {
        Picker(selection: $typeFilter) {
            Text("All Types").tag(String?.none)
            ForEach(availableTypes, id: \.self) { type in
                Text(type).tag(String?.some(type))
            }
        } label: {
            Label("Type", systemImage: "tag")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(availableTypes.isEmpty)
    }

    private var appPicker: some View {
        Picker(selection: $appFilter) {
            Text("All Apps").tag(String?.none)
            ForEach(availableApps, id: \.self) { app in
                Text(app).tag(String?.some(app))
            }
        } label: {
            Label("App", systemImage: "app.badge")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(availableApps.isEmpty)
    }
}
