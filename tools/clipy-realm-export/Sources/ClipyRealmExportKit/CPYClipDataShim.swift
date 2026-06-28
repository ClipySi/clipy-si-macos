//
//  CPYClipDataShim.swift
//  ClipyRealmExportKit
//
//  A secure-coding shim for the original Clipy `CPYClipData` archive (the per-clip `.data` file;
//  repos/Clipy CPYClipData.swift). The original class is plain `NSCoding` (NOT NSSecureCoding) — we
//  do NOT reuse it. Instead we map the archived class name "CPYClipData" to THIS shim
//  (`supportsSecureCoding = true`) and decode with `requiresSecureCoding = true`, reading ONLY the
//  text-relevant keys (`types`, `stringValue`). The image/PDF/RTF/file keys are never decoded, so an
//  image-only clip just yields empty text (→ skipped) and no NSImage is ever instantiated from
//  untrusted bytes.
//

import Foundation

final class CPYClipDataShim: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    // The original keyed-archive names (verbatim, incl. the singular "URL" and lower-case "filenames"
    // sic) — we only read `types` + `stringValue`.
    private enum Key {
        static let types = "types"
        static let stringValue = "stringValue"
    }

    let types: [String]
    let stringValue: String

    init(types: [String], stringValue: String) {
        self.types = types
        self.stringValue = stringValue
        super.init()
    }

    required init?(coder: NSCoder) {
        let decodedTypes = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.types) as? [String]
        types = decodedTypes ?? []
        stringValue = (coder.decodeObject(of: NSString.self, forKey: Key.stringValue) as String?) ?? ""
        super.init()
    }

    func encode(with coder: NSCoder) {
        // Encoding is only used by the tests to build fixtures in the original's archive shape.
        coder.encode(types as NSArray, forKey: Key.types)
        coder.encode(stringValue as NSString, forKey: Key.stringValue)
    }
}

/// Securely decodes an original `.data` archive and returns its plain text, or nil when the clip
/// carries no decodable plain text (image/PDF/file-only, or a corrupt archive — per-clip isolation).
public enum ClipDataDecoder {
    /// The archived root class name in the original `.data` files. `NSKeyedArchiver` stored the Swift
    /// class module-qualified, so REAL Clipy data uses "Clipy.CPYClipData" (verified by inspecting the
    /// archives' `$classname`). The fixtures encode with this same name; `archivedClassNameAliases` also
    /// maps the bare "CPYClipData" so a differently-built archive still decodes.
    static let archivedClassName = "Clipy.CPYClipData"
    private static let archivedClassNameAliases = ["Clipy.CPYClipData", "CPYClipData"]

    public static func plainText(fromArchivedData data: Data) -> String? {
        guard let shim = try? secureDecode(data) else { return nil }
        return shim.stringValue.isEmpty ? nil : shim.stringValue
    }

    static func secureDecode(_ data: Data) throws -> CPYClipDataShim {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        for className in archivedClassNameAliases {
            unarchiver.setClass(CPYClipDataShim.self, forClassName: className)
        }
        defer { unarchiver.finishDecoding() }
        guard let shim = unarchiver.decodeObject(of: CPYClipDataShim.self, forKey: NSKeyedArchiveRootObjectKey) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return shim
    }
}
