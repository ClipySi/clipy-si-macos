//
//  DiagnosticTypes.swift
//  ClipySi — Apple Silicon rewrite
//
//  The typed diagnostics layer. The whole point of these types is what they CANNOT
//  express: there is no way to attach clipboard content, a clip title, a search query, a
//  snippet body, an email, or a token to a diagnostic. Every payload is an enum or a number,
//  and the only free-form `String`s in the encoded envelope are app-controlled metadata
//  (app/OS version). This is the *single structural guarantee* that the redaction CI gate
//  protects — see security-guidance.md §5.
//
//  There is no network sink: distribution is Developer ID direct + GitHub Releases and macOS
//  crashes flow through Apple's Organizer (OS-level opt-in, body-free). "Diagnostics" here means
//  *local* collection the user can optionally export and attach to a bug report. `DiagnosticLevel`
//  controls collection granularity, not a send granularity (nothing is ever sent automatically).
//

import Foundation

/// How much the app collects locally. Default `.none` (collect nothing — not even an
/// installation ID). Ordered so call sites can gate on `level >= .minimal`. The granularity of
/// each level mirrors the crash-report table documented in the privacy policy.
enum DiagnosticLevel: String, Codable, Comparable, CaseIterable, Sendable {
    /// Collect nothing. The safe default.
    case none
    /// Crash stack trace (via MetricKit) + environment (app/OS version, CPU arch).
    case minimal
    /// `.minimal` + coarse feature area on errors + sync provider type.
    case standard
    /// `.standard` + recent coarse breadcrumbs (feature areas used). Still no body data.
    case detailed

    private var order: Int {
        switch self {
        case .none: 0
        case .minimal: 1
        case .standard: 2
        case .detailed: 3
        }
    }

    static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool { lhs.order < rhs.order }

    /// Decode a persisted raw value, falling back to the safe `.none` for any unknown/absent string.
    init(raw: String?) {
        self = raw.flatMap(DiagnosticLevel.init(rawValue:)) ?? .none
    }
}

/// A coarse subsystem bucket. The raw values are a *fixed enumeration of tokens* (not user data),
/// so the redaction Mirror check allow-lists this type's `String` rawValue.
enum FeatureArea: String, Codable, CaseIterable, Sendable {
    case app, capture, menu, paste, history, snippets, settings, update, hotkey, security, sync
}

/// The kind of sync backend in use. Only `.none` exists today; the cases are a forward hook
/// so a diagnostic can record "sync was active" without naming an account or endpoint.
enum SyncProviderType: String, Codable, CaseIterable, Sendable {
    case none
}

/// The running CPU slice. Resolved from `uname` so a universal binary reports the slice actually
/// executing (e.g. `x86_64` under Rosetta), which is what a crash investigation needs.
enum CPUArchitecture: String, Codable, CaseIterable, Sendable {
    // "x86_64" is the canonical arch token (matches `uname` output); allow the underscore.
    // swiftlint:disable:next identifier_name
    case arm64, x86_64, unknown

    static var current: CPUArchitecture {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if machine.hasPrefix("arm64") { return .arm64 }
        if machine.hasPrefix("x86_64") { return .x86_64 }
        return .unknown
    }
}

/// A coarse failure classification. Deliberately carries no underlying-error string — an
/// `Error.localizedDescription` could in principle echo a path or value, so diagnostics record
/// only the *category*.
enum DiagnosticErrorKind: String, Codable, CaseIterable, Sendable {
    case ioFailure, decodeFailure, encryptionFailure, permissionDenied, unexpectedNil, other
}

/// The ONLY thing the app can record. Associated values are enums — there is no `String`/`Data`
/// case, so by construction a caller cannot smuggle clipboard content into a diagnostic.
enum DiagnosticEvent: Codable, Equatable, Sendable {
    /// App finished launching (a coarse lifecycle marker).
    case launched
    /// A feature area was exercised (a breadcrumb).
    case featureUsed(FeatureArea)
    /// A coarse error occurred in a feature area.
    case error(FeatureArea, DiagnosticErrorKind)
    /// A MetricKit crash payload was received.
    case crashReceived

    /// The minimum collection level at which this event is retained. Mirrors idea-list's table:
    /// crashes at `.minimal`, coarse lifecycle/errors at `.standard`, breadcrumbs at `.detailed`.
    var minimumLevel: DiagnosticLevel {
        switch self {
        case .crashReceived: .minimal
        case .launched, .error: .standard
        case .featureUsed: .detailed
        }
    }
}

/// An event stamped with when it happened.
struct TimestampedEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: DiagnosticEvent
}

/// App-controlled environment metadata. None of these fields is user data: versions come from the
/// bundle/OS, `cpuArch` from `uname`, `installationID` is an anonymous UUID generated on-device only
/// at `level >= .minimal`, and `syncProviderType` is a fixed enum.
struct DiagnosticEnvironment: Codable, Equatable, Sendable {
    let appVersion: String
    let build: String
    let osVersion: String
    let cpuArch: CPUArchitecture
    let syncProviderType: SyncProviderType
    /// Anonymous, on-device-generated. `nil` unless the user opted into `.minimal`+.
    let installationID: String?

    static func current(installationID: String?,
                        syncProviderType: SyncProviderType = .none,
                        bundle: Bundle = .main,
                        processInfo: ProcessInfo = .processInfo) -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            osVersion: processInfo.operatingSystemVersionString,
            cpuArch: .current,
            syncProviderType: syncProviderType,
            installationID: installationID
        )
    }
}

/// The exportable diagnostic bundle. This is the *only* shape that reaches JSON, so the redaction
/// canary test needs to scan just this type's encoding to prove no body data can escape.
struct DiagnosticEnvelope: Codable, Equatable, Sendable {
    let level: DiagnosticLevel
    let environment: DiagnosticEnvironment
    let events: [TimestampedEvent]
}
