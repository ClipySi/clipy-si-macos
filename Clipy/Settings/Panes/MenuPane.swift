//
//  MenuPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Menu settings pane: history-dedupe behavior, item numbering/limits, tool tips, thumbnail
//  appearance, and the clear-history menu item. Two-way bound to the verbatim original keys via
//  `@Shared(.appStorage)`; numeric fields re-apply the original's formatter minimums and
//  child controls mirror `.disabled(!parent)` (design §2.2). All keys already exist in
//  `DefaultsKeys`/`AppSettings`.
//

import SwiftUI
import Sharing

struct MenuPane: View {
    @Shared(.appStorage(DefaultsKeys.copySameHistory)) private var copySameHistory = true
    @Shared(.appStorage(DefaultsKeys.overwriteSameHistory)) private var overwriteSameHistory = true
    @Shared(.appStorage(DefaultsKeys.maxMenuItemTitleLength)) private var titleLength = 20
    @Shared(.appStorage(DefaultsKeys.menuItemsAreMarkedWithNumbers)) private var markedWithNumbers = true
    @Shared(.appStorage(DefaultsKeys.menuItemsTitleStartWithZero)) private var startWithZero = false
    @Shared(.appStorage(DefaultsKeys.historyPanelItemsPerPage)) private var panelItemsPerPage = 10
    @Shared(.appStorage(DefaultsKeys.showToolTipOnMenuItem)) private var showToolTip = true
    @Shared(.appStorage(DefaultsKeys.maxLengthOfToolTip)) private var toolTipLength = 200
    @Shared(.appStorage(DefaultsKeys.showImageInTheMenu)) private var showImage = true
    @Shared(.appStorage(DefaultsKeys.thumbnailWidth)) private var thumbnailWidth = 100
    @Shared(.appStorage(DefaultsKeys.thumbnailHeight)) private var thumbnailHeight = 32
    @Shared(.appStorage(DefaultsKeys.showColorPreviewInTheMenu)) private var showColorPreview = true
    @Shared(.appStorage(DefaultsKeys.showIconInTheMenu)) private var showIcon = true
    @Shared(.appStorage(DefaultsKeys.addClearHistoryMenuItem)) private var addClearHistory = true
    @Shared(.appStorage(DefaultsKeys.showAlertBeforeClearHistory)) private var showAlertBeforeClear = true

    var body: some View {
        Form {
            Section("History") {
                Toggle("Place already copied history at the top", isOn: Binding($copySameHistory))
                Toggle("Move instead of copying (removes the older one from the list)",
                       isOn: Binding($overwriteSameHistory))
                    .disabled(!copySameHistory)
            }

            Section("Numbering") {
                IntFieldRow(title: "Number of characters in the menu:", unit: "chars",
                            value: Binding($titleLength), range: 1...1000)
                Toggle("Mark menu items with numbers", isOn: Binding($markedWithNumbers))
                Toggle("Menu items' title starts with 0", isOn: Binding($startWithZero))
                    .disabled(!markedWithNumbers)
                IntFieldRow(title: "Items per page in the history panel:", unit: "items",
                            value: Binding($panelItemsPerPage),
                            range: SettingsMapping.historyPanelItemsPerPageRange)
            }

            Section("Tool tip") {
                Toggle("Show tool tip on a menu item", isOn: Binding($showToolTip))
                IntFieldRow(title: "Max length of tool tip string:", unit: "chars",
                            value: Binding($toolTipLength), range: 1...10_000)
                    .disabled(!showToolTip)
            }

            Section("Appearance") {
                Toggle("Show Image", isOn: Binding($showImage))
                IntFieldRow(title: "Width:", unit: "pixel",
                            value: Binding($thumbnailWidth), range: 1...1000)
                    .disabled(!showImage)
                IntFieldRow(title: "Height:", unit: "pixel",
                            value: Binding($thumbnailHeight), range: 1...1000)
                    .disabled(!showImage)
                Toggle("Show color code preview", isOn: Binding($showColorPreview))
                Toggle("Display icons in menu items", isOn: Binding($showIcon))
            }

            Section("Clear history") {
                Toggle("Add a menu item to clear clipboard history", isOn: Binding($addClearHistory))
                Toggle("Show alert panel before clear history", isOn: Binding($showAlertBeforeClear))
                    .disabled(!addClearHistory)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
        .frame(minHeight: 420, maxHeight: 600)
    }
}
