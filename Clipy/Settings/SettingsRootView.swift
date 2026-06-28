//
//  SettingsRootView.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Settings window root. Five preference panes (General / Menu / Type / Excluded Apps /
//  Shortcuts) selected from an **icon-only** tab bar — each tab is an SF Symbol button whose name
//  appears as a fast custom tooltip on hover (and as the accessibility label). The tooltip is a root
//  overlay positioned via an anchor preference under the hovered tab, so it draws above the pane and
//  shows after a short ~0.4 s delay (the standard `.help` tooltip's ~1.5 s delay read as "missing").
//  The former "Updates" tab was carved out into the standalone About window (see AboutView /
//  AppDelegate.openAbout); the former "Beta" tab's features graduated into General (paste actions)
//  and Type (screenshots).
//
//  This replaces SwiftUI's `TabView`: the macOS tab bar can't render icon-only tabs with per-tab
//  tooltips, so we drive selection ourselves and switch the pane below a thin custom bar. Window
//  sizing is unchanged — AppDelegate hosts this at a fixed `SettingsLayout.windowContentSize`, and
//  each pane keeps its own `paneWidth`. See DESIGN.md §4.6 and the design §1.2/§3.
//

import SwiftUI

struct SettingsRootView: View {
    private enum Tab: CaseIterable, Hashable {
        case general, menu, type, excludedApps, shortcuts, privacy, sync, diagnostics

        /// Localized name — shown as the tooltip + accessibility label (keys already in the catalog).
        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .menu: "Menu"
            case .type: "Type"
            case .excludedApps: "Excluded Apps"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy"
            case .sync: "Sync"
            case .diagnostics: "Diagnostics"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .menu: "menubar.rectangle"
            case .type: "doc.on.doc"
            case .excludedApps: "xmark.app"
            case .shortcuts: "keyboard"
            case .privacy: "lock.shield"
            case .sync: "arrow.triangle.2.circlepath"
            case .diagnostics: "stethoscope"
            }
        }
    }

    @State private var selection: Tab = .general

    /// The tab the cursor is currently over (drives the hover highlight and starts the tooltip timer).
    @State private var hoveredTab: Tab?
    /// The tab whose tooltip is actually shown — set only after the hover delay elapses, so a quick
    /// pass over the bar doesn't flash labels.
    @State private var tooltipTab: Tab?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Render the tooltip at the root (after the pane) so it layers *above* the pane content; an
        // overlay inside the tab bar would be painted over by the later-drawn pane sibling.
        .overlayPreferenceValue(TabBoundsKey.self) { anchors in
            GeometryReader { proxy in
                if let tooltipTab, let anchor = anchors[tooltipTab] {
                    let rect = proxy[anchor]
                    TabTooltip(title: tooltipTab.title)
                        .position(x: rect.midX, y: rect.maxY + 16)
                }
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: tooltipTab)
        }
        // Hover → wait ~0.4 s → show. `.task(id:)` cancels and restarts whenever the hovered tab
        // changes, so moving off the bar (nil) hides immediately and moving between tabs re-arms the
        // delay rather than flashing the previous label.
        .task(id: hoveredTab) {
            guard hoveredTab != nil else { tooltipTab = nil; return }
            if tooltipTab != hoveredTab { tooltipTab = nil } // drop a stale label while we wait
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { tooltipTab = hoveredTab }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabButton(symbol: tab.symbol,
                          title: tab.title,
                          isSelected: selection == tab,
                          isHovered: hoveredTab == tab,
                          action: { selection = tab },
                          onHover: { hovering in
                              hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                          })
                    // Publish each tab's frame so the root overlay can place the tooltip under it.
                    .anchorPreference(key: TabBoundsKey.self, value: .bounds) { [tab: $0] }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var pane: some View {
        switch selection {
        case .general: GeneralPane()
        case .menu: MenuPane()
        case .type: TypePane()
        case .excludedApps: ExcludedAppsPane()
        case .shortcuts: ShortcutsPane()
        case .privacy: PrivacyPane()
        case .sync: SyncPane(coordinator: .shared)
        case .diagnostics: DiagnosticsPane()
        }
    }

    /// Collects each tab's bounds (in the root's space) so the tooltip overlay can be placed under the
    /// hovered tab without hardcoding the bar geometry. Last writer wins — keys are distinct per tab.
    private struct TabBoundsKey: PreferenceKey {
        static let defaultValue: [Tab: Anchor<CGRect>] = [:]

        static func reduce(value: inout [Tab: Anchor<CGRect>],
                           nextValue: () -> [Tab: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

/// A single icon-only tab: an SF Symbol button with a selection highlight and a hover highlight. The
/// pane name is surfaced by the parent's custom tooltip (driven by `onHover`) and as the
/// accessibility label here. Hover state is owned by the parent so the tooltip and the highlight stay
/// in sync from one source.
private struct TabButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 46, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(background)
        }
        .onHover(perform: onHover)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: AnyShapeStyle {
        if isSelected {
            AnyShapeStyle(Color.accentColor.opacity(0.15))
        } else if isHovered {
            AnyShapeStyle(.quaternary)
        } else {
            AnyShapeStyle(.clear)
        }
    }
}

/// The hover tooltip bubble shown under a tab. A small capsule over a material backing with a hairline
/// border and soft shadow — close to the system tooltip look, but ours so we control the timing.
private struct TabTooltip: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            // Fade/slide in so the appearance reads as a tooltip, not a layout jump.
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    SettingsRootView()
        .frame(width: SettingsLayout.windowContentSize.width,
               height: SettingsLayout.windowContentSize.height)
}
