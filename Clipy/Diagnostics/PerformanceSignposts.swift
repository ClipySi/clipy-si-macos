//
//  PerformanceSignposts.swift
//  ClipySi — Apple Silicon rewrite
//
//  Points-of-interest intervals over the history-panel open path (M-UI.11, history-performance
//  plan v2 §P0). Instruments' os_signpost / Points of Interest track picks these up on a Release
//  build, so the reported 0.5–0.8 s open can be attributed per stage: DB fetch → decrypt+mask →
//  classify → snippet build → model commit → order-front. `PanelSearchFilter` /
//  `PanelCategoryCounts` fire on every SwiftUI recomputation, making the body-time O(N) pipelines
//  visible (and countable) before P1 replaces them with a stored snapshot.
//
//  Non-leak contract (plan v2 §3.2): interval metadata carries ONLY row counts — never clip
//  content, search text, clip IDs, or bundle ids.
//

import OSLog

/// Interval markers for the panel-open pipeline stages.
///
/// `measure(_:rows:_:)` wraps a synchronous stage; `begin(_:)`/`end(_:_:rows:)` bracket the two
/// open-level intervals whose endpoints live in different statements of
/// `HistoryPanelController.show()`. Names are stable identifiers for Instruments filtering and the
/// baseline report — rename only alongside the measurement docs.
enum PanelSignpost {
    enum Stage {
        /// Panel open → the panel is on screen and key (the show-first target: < 100 ms).
        case openToShell
        /// Panel open → the first rows are committed to the model (currently the same synchronous
        /// span as `openToShell`, which is exactly the baseline problem being measured).
        case openToFirstRows
        /// The history SELECT (`recentClips`) — row I/O without decryption.
        case historyFetch
        /// AES-GCM open + redaction-core evaluate over every fetched title (one combined pass in
        /// `ClipDisplayBuilder`; the finer decrypt/mask split lives in the baseline tests).
        case historyDecryptMask
        /// `CodeClassifier` + content-kind mapping over every display row.
        case historyClassify
        /// Snippet folder/row build (the N+1 folder queries live behind this today).
        case snippetRowsBuild
        /// `HistoryPanelModel.reset` — the MainActor state commit.
        case modelCommit
        /// One recomputation of `filteredRows` (scope → category → search over all rows).
        case searchFilter
        /// One recomputation of `categoryCounts` (a second full-array pass today).
        case categoryCounts
        /// The History Manager's page/facet SELECT (M-UI.11 P5) — distinct from the panel's
        /// `historyFetch` so baseline dashboards don't mix the two surfaces' traffic.
        case managerFetch
        /// The manager's decrypt+mask pass (page build or one scan batch).
        case managerDecryptMask
    }

    private static let signposter = OSSignposter(
        subsystem: "io.github.ponponusa.clipysi", category: .pointsOfInterest)

    static func begin(_ stage: Stage) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        switch stage {
        case .openToShell: return signposter.beginInterval("PanelOpenToShell", id: id)
        case .openToFirstRows: return signposter.beginInterval("PanelOpenToFirstRows", id: id)
        case .historyFetch: return signposter.beginInterval("HistoryDBFetch", id: id)
        case .historyDecryptMask: return signposter.beginInterval("HistoryDecryptMask", id: id)
        case .historyClassify: return signposter.beginInterval("HistoryRowClassify", id: id)
        case .snippetRowsBuild: return signposter.beginInterval("SnippetRowsBuild", id: id)
        case .modelCommit: return signposter.beginInterval("PanelModelCommit", id: id)
        case .searchFilter: return signposter.beginInterval("PanelSearchFilter", id: id)
        case .categoryCounts: return signposter.beginInterval("PanelCategoryCounts", id: id)
        case .managerFetch: return signposter.beginInterval("ManagerDBFetch", id: id)
        case .managerDecryptMask: return signposter.beginInterval("ManagerDecryptMask", id: id)
        }
    }

    /// Ends the interval. `rows` is the row count the stage operated on (−1 = not applicable);
    /// counts are the ONLY metadata a stage may attach.
    static func end(_ stage: Stage, _ state: OSSignpostIntervalState, rows: Int = -1) {
        switch stage {
        case .openToShell: signposter.endInterval("PanelOpenToShell", state, "rows=\(rows, privacy: .public)")
        case .openToFirstRows: signposter.endInterval("PanelOpenToFirstRows", state, "rows=\(rows, privacy: .public)")
        case .historyFetch: signposter.endInterval("HistoryDBFetch", state, "rows=\(rows, privacy: .public)")
        case .historyDecryptMask: signposter.endInterval("HistoryDecryptMask", state, "rows=\(rows, privacy: .public)")
        case .historyClassify: signposter.endInterval("HistoryRowClassify", state, "rows=\(rows, privacy: .public)")
        case .snippetRowsBuild: signposter.endInterval("SnippetRowsBuild", state, "rows=\(rows, privacy: .public)")
        case .modelCommit: signposter.endInterval("PanelModelCommit", state, "rows=\(rows, privacy: .public)")
        case .searchFilter: signposter.endInterval("PanelSearchFilter", state, "rows=\(rows, privacy: .public)")
        case .categoryCounts: signposter.endInterval("PanelCategoryCounts", state, "rows=\(rows, privacy: .public)")
        case .managerFetch: signposter.endInterval("ManagerDBFetch", state, "rows=\(rows, privacy: .public)")
        case .managerDecryptMask: signposter.endInterval("ManagerDecryptMask", state, "rows=\(rows, privacy: .public)")
        }
    }

    /// Wraps a synchronous stage. `rows` may be the input count when the output count isn't
    /// knowable up front — either says "how much data this stage walked".
    static func measure<T>(_ stage: Stage, rows: Int = -1, _ body: () throws -> T) rethrows -> T {
        let state = begin(stage)
        defer { end(stage, state, rows: rows) }
        return try body()
    }

    /// Wraps a stage whose walked-row count IS the result's count (knowable only when the body
    /// returns) — e.g. a SELECT whose LIMIT is a configured cap, not the actual row flow. The
    /// error path still balances the interval (with rows unknown).
    static func measureCounted<T>(_ stage: Stage, _ body: () throws -> [T]) rethrows -> [T] {
        let state = begin(stage)
        do {
            let result = try body()
            end(stage, state, rows: result.count)
            return result
        } catch {
            end(stage, state)
            throw error
        }
    }
}
