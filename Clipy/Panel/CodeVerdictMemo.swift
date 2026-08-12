//
//  CodeVerdictMemo.swift
//  ClipySi — Apple Silicon rewrite
//
//  The classifier memo CORE shared by the two classification tiers (M-UI.11 P4 review: they
//  were two hand-kept copies that had already begun to drift): `PanelClassificationCache`
//  (MainActor — visible pages, in-memory narrowing) and the progressive scan (the
//  `HistoryReadService` actor) each own an instance, so one key discipline, one eviction
//  policy, and one verdict application exist for both executors. Keys include the clip's
//  `updatedAt` and the request's `DisplayPolicy` (mask settings + classifier algorithm
//  version), so a row mutation, a mask change, or a classifier bump each make the old entry
//  unreachable. Verdicts are an enum + flag — never title text.
//
//  Eviction drops a quarter of the entries when full, NOT the whole store (P4 review): a
//  window larger than the capacity would otherwise clear the memo once per walk and re-run
//  the ~220 µs/row classifier for every row of every scan.
//

import Foundation

struct CodeVerdictMemo {
    struct Key: Hashable {
        let id: RowID
        let updatedAt: Date?
        let policy: DisplayPolicy
    }

    /// Hit/miss counters — the P1 tests pin the caching contract on these (a re-open must not
    /// re-classify unchanged rows; a policy/version change must never hit).
    struct Stats: Equatable {
        var hits = 0
        var misses = 0
    }

    private(set) var stats = Stats()
    /// `.some(nil)` = memoized "not code".
    private var verdicts: [Key: CodeClassifier.Language?] = [:]
    private let capacity: Int

    init(capacity: Int = 8_192) {
        self.capacity = capacity
    }

    /// `row` with its `needsCodeClassification` resolved (flag cleared; `.code` + language
    /// filled when the classifier says so). Rows without the flag pass through untouched.
    mutating func resolve(_ row: PanelRow, policy: DisplayPolicy) -> PanelRow {
        guard row.needsCodeClassification else { return row }
        var resolved = row
        resolved.needsCodeClassification = false
        let key = Key(id: row.id, updatedAt: row.updatedAt, policy: policy)
        let language: CodeClassifier.Language?
        if let cached = verdicts[key] {
            stats.hits += 1
            language = cached
        } else {
            stats.misses += 1
            if verdicts.count >= capacity {
                for stale in verdicts.keys.prefix(capacity / 4) {
                    verdicts.removeValue(forKey: stale)
                }
            }
            language = CodeClassifier.classify(row.title)
            verdicts[key] = language
        }
        if let language {
            resolved.contentKind = .code
            resolved.codeLanguage = language.rawValue
        }
        return resolved
    }
}
