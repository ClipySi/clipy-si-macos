//
//  CPYClip.swift
//  ClipyRealmExportKit
//
//  Read-only mirror of the original Clipy's `CPYClip` Realm row (repos/Clipy CPYClip.swift) — only
//  the fields the extractor reads. The class name MUST stay "CPYClip" so Realm maps it to the stored
//  table. CPYClip is all-scalar (no relationships), so opening the realm with
//  `objectTypes: [CPYClip.self]` lets us ignore the snippet/folder tables entirely.
//
//  Declared with the legacy `@objc dynamic var` + `primaryKey()` syntax (NOT the `@Persisted`
//  property wrapper) because we pin RealmSwift 10.7.2 / realm-core 10.5.5 — the version Clipy 1.2.2
//  uses — which is the realm-core that can still READ the original's file-format-9 database. The
//  modern `@Persisted` attribute only exists from RealmSwift 10.10+.
//

import Foundation
import RealmSwift

public final class CPYClip: Object {
    @objc public dynamic var dataPath = ""
    @objc public dynamic var title = ""
    @objc public dynamic var dataHash = ""
    @objc public dynamic var primaryType = ""
    @objc public dynamic var updateTime = 0
    @objc public dynamic var thumbnailPath = ""
    @objc public dynamic var isColorCode = false

    override public static func primaryKey() -> String? {
        return "dataHash"
    }
}
