//
//  ClipRepository+Manager.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P5: the History Manager's SQL read surface — metadata filter, sort push-down, count,
//  and facet (distinct Type/App) queries, all over the live set only. Replaces the manager's
//  500-row eager window: a page fetch serves `limit` rows of the FILTERED, SORTED live history
//  from a keyset cursor, so open cost is a page, not the corpus (plan v2 §5.6).
//
//  Sort keys are METADATA columns only (`createdAt`, `sourceBundle`, `primaryType`, `isPinned`) —
//  the preview is an AES-GCM ciphertext, so preview ordering cannot be pushed down and is not
//  offered (§5.6 lists exactly these four). The app key sorts by `coalesce(sourceBundle, '')`:
//  the ORDER BY and the cursor predicate MUST use the same expression, because NULL-vs-'' rows
//  are interleaved by display (both show "") and a bare-column order with a coalesced predicate
//  would drop rows at the group boundary. Cursor predicates use the expanded OR form — these
//  sorts have no covering index, so there is no row-value index seek to preserve (§4.3), and no
//  new index is added without measurement (plan §5.2).
//
//  `deletedAt IS NULL` is fixed inside `managerBase` — every manager read path (page, count,
//  facets, the P5 scan walk) goes through it, so the P0-C tombstone-leak class (an explicit
//  load dropping the filter) is structurally gone.
//

import Foundation
import GRDB
import SQLiteData

/// The History Manager's metadata narrowing — resolved to RAW column values (not display
/// labels) by the store. `nil` means "no narrowing" on that axis.
struct ManagerRowFilter: Sendable, Hashable {
    /// Exact `primaryType` values to keep (OR-ed) — one display label can cover several raws.
    var primaryTypes: [String]?
    /// Exact `sourceBundle` value to keep. Rows with NULL `sourceBundle` never match a
    /// selection (the App menu only offers non-empty bundles, as the 500-row window did).
    var sourceBundle: String?

    static let none = ManagerRowFilter()
}

/// One sortable column + direction for the manager table (plan v2 §5.6 push-down set).
struct ManagerSort: Sendable, Hashable {
    enum Key: Sendable, Hashable {
        case date, app, type, pinned
    }

    var key: Key
    var ascending: Bool

    /// The manager's natural order and the table's initial sort.
    static let newestFirst = ManagerSort(key: .date, ascending: false)
}

/// A stable position in one manager sort order: the sort-key VALUE of the last served row plus
/// the `(createdAt, id)` tie-break — values, not a row reference, so the cursor keeps meaning
/// "rows after this position" when rows are mutated or deleted between pages (the P2 keyset
/// property, extended to composite keys).
struct ManagerPageCursor: Sendable, Hashable {
    enum SortValue: Sendable, Hashable {
        /// Date sort — `(createdAt, id)` alone is the full key.
        case none
        /// App (`coalesce(sourceBundle, '')`) or type (`primaryType`) sort.
        case text(String)
        /// Pinned sort.
        case flag(Bool)
    }

    let sortValue: SortValue
    let createdAt: Date
    let id: UUID
}

extension ManagerSort {
    /// The cursor value continuing this sort after `clip` — MUST mirror the key expressions in
    /// `ClipRepository.managerFetch` (app uses the coalesced value).
    func cursorValue(of clip: Clip) -> ManagerPageCursor.SortValue {
        switch key {
        case .date: .none
        case .app: .text(clip.sourceBundle ?? "")
        case .type: .text(clip.primaryType)
        case .pinned: .flag(clip.isPinned)
        }
    }

    /// The SAME total order the SQL push-down produces, for in-memory merging of scan matches:
    /// key first (SQLite BINARY collation = UTF-8 byte order — NOT Swift's Unicode ordering),
    /// then `createdAt` DESC, then id (UUID TEXT order) as the tie-break. Date sort honors
    /// `ascending`; metadata groups always order newest-first inside, matching `managerFetch`.
    func areInOrder(_ first: HistoryClipRow, _ second: HistoryClipRow) -> Bool {
        switch key {
        case .date:
            break
        case .app:
            // Equality must be byte-wise like the ordering: Swift `==` is canonical
            // equivalence, which would fuse NFC/NFD strings BINARY keeps as distinct,
            // non-adjacent groups (review).
            if !binaryEqual(first.sourceBundleDisplay, second.sourceBundleDisplay) {
                let precedes = binaryLess(first.sourceBundleDisplay, second.sourceBundleDisplay)
                return ascending ? precedes : !precedes
            }
        case .type:
            if !binaryEqual(first.primaryType, second.primaryType) {
                let precedes = binaryLess(first.primaryType, second.primaryType)
                return ascending ? precedes : !precedes
            }
        case .pinned:
            if first.isPinned != second.isPinned {
                // false < true, mirroring INTEGER 0 < 1.
                return ascending ? !first.isPinned : first.isPinned
            }
        }
        if first.createdAt != second.createdAt {
            let newestFirstTie = key != .date || !ascending
            return newestFirstTie ? first.createdAt > second.createdAt : first.createdAt < second.createdAt
        }
        // Uppercase hex compares in the same relative order as the stored lowercase TEXT
        // (digits < letters, letters alphabetical in both cases), so `uuidString` works as-is.
        let newestFirstTie = key != .date || !ascending
        return newestFirstTie
            ? first.id.uuidString > second.id.uuidString
            : first.id.uuidString < second.id.uuidString
    }

    /// SQLite BINARY collation — UTF-8 byte order.
    private func binaryLess(_ first: String, _ second: String) -> Bool {
        first.utf8.lexicographicallyPrecedes(second.utf8)
    }

    private func binaryEqual(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }
}

/// One manager read: the page, plus (when asked) the filtered count and the facet lists, all
/// from ONE read transaction so a concurrent write can't shear the count against the rows
/// (the P3 shear lesson, applied to the manager).
struct ManagerPageData: Sendable {
    var page: [Clip] = []
    var filteredCount: Int?
    /// DISTINCT `primaryType` of the whole live set (unfiltered — the menus offer everything).
    var typeRawValues: [String]?
    /// DISTINCT non-NULL `sourceBundle` of the whole live set.
    var apps: [String]?
}

/// What a manager page read carries beyond the rows.
struct ManagerReadOptions: OptionSet, Sendable {
    let rawValue: Int

    /// The filtered live count, in the same transaction as the rows.
    static let count = ManagerReadOptions(rawValue: 1 << 0)
    /// The distinct Type/App facet lists of the whole live set.
    static let facets = ManagerReadOptions(rawValue: 1 << 1)
}

extension ClipRepository {
    func managerPage(filter: ManagerRowFilter, sort: ManagerSort, after cursor: ManagerPageCursor?,
                     limit: Int, options: ManagerReadOptions) throws -> ManagerPageData {
        try database.read { db in
            ManagerPageData(
                page: try Self.managerFetch(db, filter: filter, sort: sort, after: cursor, limit: limit),
                filteredCount: options.contains(.count)
                    ? try Self.managerBase(filter).fetchCount(db) : nil,
                // Facets go through `managerBase` too (unfiltered) — the tombstone predicate
                // must have exactly one author (the P0-C leak class was a restated filter).
                typeRawValues: options.contains(.facets)
                    ? try Self.managerBase(.none).select(\.primaryType).distinct().fetchAll(db)
                    : nil,
                apps: options.contains(.facets)
                    ? try Self.managerBase(.none).where { $0.sourceBundle.isNot(nil) }
                        .select { $0.sourceBundle ?? "" }.distinct().fetchAll(db)
                    : nil)
        }
    }

    /// The ordered, filtered, cursor-continued live fetch behind every manager page and the P5
    /// scan walk. Like `fetchLive`, this is THE one query body for the manager's order
    /// contract; the date branches delegate to the same key shapes `fetchLive` uses, and a
    /// parity test pins the two against each other.
    static func managerFetch(_ db: Database, filter: ManagerRowFilter, sort: ManagerSort,
                             after cursor: ManagerPageCursor?, limit: Int) throws -> [Clip] {
        let cap = max(0, limit) // LIMIT -1 would mean "no limit" (the fetchLive clamp)
        let base = managerBase(filter)
        switch sort.key {
        case .date:
            return try fetchByDate(db, base: base, ascending: sort.ascending, cursor: cursor, cap: cap)
        case .app:
            return try fetchByApp(db, base: base, ascending: sort.ascending, cursor: cursor, cap: cap)
        case .type:
            return try fetchByType(db, base: base, ascending: sort.ascending, cursor: cursor, cap: cap)
        case .pinned:
            return try fetchByPinned(db, base: base, ascending: sort.ascending, cursor: cursor, cap: cap)
        }
    }

    /// `deletedAt IS NULL` plus the metadata narrowing — the manager's only base predicate.
    private static func managerBase(_ filter: ManagerRowFilter) -> Where<Clip> {
        var base = Clip.where { $0.deletedAt.is(nil) }
        if let types = filter.primaryTypes {
            base = base.where { $0.primaryType.in(types) }
        }
        if let app = filter.sourceBundle {
            base = base.where { $0.sourceBundle.eq(app) }
        }
        return base
    }

    private static func fetchByDate(_ db: Database, base: Where<Clip>, ascending: Bool,
                                    cursor: ManagerPageCursor?, cap: Int) throws -> [Clip] {
        var query = base
        if let cursor {
            query = query.where {
                if ascending {
                    #sql("""
                    (\($0.createdAt), \($0.id)) > \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))
                    """, as: Bool.self)
                } else {
                    #sql("""
                    (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))
                    """, as: Bool.self)
                }
            }
        }
        return ascending
            ? try query.order { ($0.createdAt.asc(), $0.id.asc()) }.limit(cap).fetchAll(db)
            : try query.order { ($0.createdAt.desc(), $0.id.desc()) }.limit(cap).fetchAll(db)
    }

    private static func fetchByApp(_ db: Database, base: Where<Clip>, ascending: Bool,
                                   cursor: ManagerPageCursor?, cap: Int) throws -> [Clip] {
        var query = base
        if let cursor, case let .text(value) = cursor.sortValue {
            query = query.where {
                if ascending {
                    #sql("""
                    (coalesce(\($0.sourceBundle), '') > \(#bind(value, as: String.self)) \
                    OR (coalesce(\($0.sourceBundle), '') = \(#bind(value, as: String.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                } else {
                    #sql("""
                    (coalesce(\($0.sourceBundle), '') < \(#bind(value, as: String.self)) \
                    OR (coalesce(\($0.sourceBundle), '') = \(#bind(value, as: String.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                }
            }
        } else if cursor != nil {
            // A cursor built under a different sort key reached this fetch — the
            // predicate would silently vanish and every page would repeat (review).
            assertionFailure("manager cursor sortValue does not match the sort key")
        }
        return ascending
            ? try query.order { (($0.sourceBundle ?? "").asc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
            : try query.order { (($0.sourceBundle ?? "").desc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
    }

    private static func fetchByType(_ db: Database, base: Where<Clip>, ascending: Bool,
                                    cursor: ManagerPageCursor?, cap: Int) throws -> [Clip] {
        var query = base
        if let cursor, case let .text(value) = cursor.sortValue {
            query = query.where {
                if ascending {
                    #sql("""
                    (\($0.primaryType) > \(#bind(value, as: String.self)) \
                    OR (\($0.primaryType) = \(#bind(value, as: String.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                } else {
                    #sql("""
                    (\($0.primaryType) < \(#bind(value, as: String.self)) \
                    OR (\($0.primaryType) = \(#bind(value, as: String.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                }
            }
        } else if cursor != nil {
            // A cursor built under a different sort key reached this fetch — the
            // predicate would silently vanish and every page would repeat (review).
            assertionFailure("manager cursor sortValue does not match the sort key")
        }
        return ascending
            ? try query.order { ($0.primaryType.asc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
            : try query.order { ($0.primaryType.desc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
    }

    private static func fetchByPinned(_ db: Database, base: Where<Clip>, ascending: Bool,
                                      cursor: ManagerPageCursor?, cap: Int) throws -> [Clip] {
        var query = base
        if let cursor, case let .flag(value) = cursor.sortValue {
            query = query.where {
                if ascending {
                    #sql("""
                    (\($0.isPinned) > \(#bind(value, as: Bool.self)) \
                    OR (\($0.isPinned) = \(#bind(value, as: Bool.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                } else {
                    #sql("""
                    (\($0.isPinned) < \(#bind(value, as: Bool.self)) \
                    OR (\($0.isPinned) = \(#bind(value, as: Bool.self)) \
                    AND (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))))
                    """, as: Bool.self)
                }
            }
        } else if cursor != nil {
            // A cursor built under a different sort key reached this fetch — the
            // predicate would silently vanish and every page would repeat (review).
            assertionFailure("manager cursor sortValue does not match the sort key")
        }
        return ascending
            ? try query.order { ($0.isPinned.asc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
            : try query.order { ($0.isPinned.desc(), $0.createdAt.desc(), $0.id.desc()) }
                .limit(cap).fetchAll(db)
    }
}
