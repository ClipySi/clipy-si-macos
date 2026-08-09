//
//  PanelClassificationCache.swift
//  ClipySi — Apple Silicon rewrite
//
//  Memoized `CodeClassifier` verdicts for panel rows (M-UI.11 P1). The P0 baseline measured
//  classification at ~220 µs/row — the single most expensive stage of the panel open — so rows are
//  built with `needsCodeClassification` set and resolved here only when something actually needs
//  the verdict: the visible page's glyphs, a title-dependent category filter (.text/.code), or the
//  chip-count badges. Keys include the clip's `updatedAt` and the request's `DisplayPolicy`
//  (mask settings + `CodeClassifier.algorithmVersion`), so a row mutation, a mask change, or a
//  classifier bump each make the old entry unreachable — there is no explicit invalidation to
//  forget. Memory only; verdicts are an enum + flag, never title text.
//

import Foundation

@MainActor
final class PanelClassificationCache {
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
    /// `.some(nil)` = cached "not code". Bounded: past `capacity` the store clears wholesale —
    /// cheap, and the next visible page re-warms exactly what is on screen.
    private var verdicts: [Key: CodeClassifier.Language?] = [:]
    private let capacity: Int

    init(capacity: Int = 8_192) {
        self.capacity = capacity
    }

    /// Returns `rows` with every `needsCodeClassification` row resolved (flag cleared; `.code` +
    /// language filled when the classifier says so). Rows without the flag pass through untouched.
    func resolve(_ rows: [PanelRow], policy: DisplayPolicy) -> [PanelRow] {
        guard rows.contains(where: \.needsCodeClassification) else { return rows }
        return PanelSignpost.measure(.historyClassify, rows: rows.count) {
            rows.map { resolveRow($0, policy: policy) }
        }
    }

    private func resolveRow(_ row: PanelRow, policy: DisplayPolicy) -> PanelRow {
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
            if verdicts.count >= capacity { verdicts.removeAll(keepingCapacity: true) }
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
