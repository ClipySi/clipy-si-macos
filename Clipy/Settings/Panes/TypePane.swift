//
//  TypePane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Type pane: which pasteboard representations capture should store. Bound to the
//  `kCPYPrefStoreTypesKey` `[String: Bool]` dictionary via `StoreTypeSettings` (off `@Shared` to
//  keep the original plist-dictionary format). Token order + labels mirror the original
//  CPYTypePreferenceViewController (design §2.3).
//
//  Also hosts the screenshot auto-import toggle (a "what gets stored" choice, graduated here from
//  the former Beta pane): it persists `observeScreenshot` and posts `.clipySiObserveScreenshotChanged`
//  so AppDelegate starts/stops the Screeen observer live (§6 delta 5).
//

import Sharing
import SwiftUI

struct TypePane: View {
    @State private var store = StoreTypeSettings()
    @Shared(.appStorage(DefaultsKeys.observeScreenshot)) private var observeScreenshot = false

    /// (token, display label) in the original's order. Tokens are `DefaultsKeys.storeTypeTokens`.
    private static let rows: [(token: String, label: LocalizedStringKey)] = [
        ("String", "Plain Text"),
        ("RTF", "Rich Text Format (RTF)"),
        ("RTFD", "Rich Text Format Directory (RTFD)"),
        ("PDF", "PDF"),
        ("Filenames", "Filenames"),
        ("URL", "URL"),
        ("TIFF", "TIFF Image")
    ]

    var body: some View {
        Form {
            Section("Select clipboard types to store:") {
                ForEach(Self.rows, id: \.token) { row in
                    Toggle(row.label, isOn: Binding(
                        get: { store.isEnabled(row.token) },
                        set: { store.setEnabled($0, for: row.token) }
                    ))
                }
            }

            Section("Screenshot") {
                Toggle("Save screenshots in history", isOn: Binding($observeScreenshot))
                    .onChange(of: observeScreenshot) { _, _ in
                        // @Shared delivers the value; AppDelegate starts/stops the Screeen observer.
                        NotificationCenter.default.post(name: .clipySiObserveScreenshotChanged, object: nil)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
    }
}
