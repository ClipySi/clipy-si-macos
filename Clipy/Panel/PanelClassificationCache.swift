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
    /// The memo core lives in `CodeVerdictMemo` (shared with the progressive scan's actor-side
    /// instance — M-UI.11 P4); this class is its MainActor face for the model tier.
    typealias Stats = CodeVerdictMemo.Stats

    private var memo: CodeVerdictMemo

    var stats: Stats { memo.stats }

    init(capacity: Int = 8_192) {
        memo = CodeVerdictMemo(capacity: capacity)
    }

    /// Returns `rows` with every `needsCodeClassification` row resolved (flag cleared; `.code` +
    /// language filled when the classifier says so). Rows without the flag pass through untouched.
    func resolve(_ rows: [PanelRow], policy: DisplayPolicy) -> [PanelRow] {
        guard rows.contains(where: \.needsCodeClassification) else { return rows }
        return PanelSignpost.measure(.historyClassify, rows: rows.count) {
            rows.map { memo.resolve($0, policy: policy) }
        }
    }
}
