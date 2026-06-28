//
//  PasteboardMonitor.swift
//  ClipySi — Apple Silicon rewrite
//
//  Watches the pasteboard's `changeCount` on a low-frequency poll (200–500ms — fixing the
//  original's 0.75ms busy-poll, NFR-PERF-1) and hands recordable changes to a handler. Privacy
//  markers are checked from the declared types BEFORE content is read (R1).
//
//  Self-writes (our own paste) are suppressed via `markSeen()` so we don't re-capture what
//  we just put on the pasteboard.
//

import Foundation

@MainActor
final class PasteboardMonitor {
    private let pasteboard: any PasteboardReading
    private let interval: Duration
    private let onChange: (PasteboardContents) -> Void
    private var lastChangeCount: Int
    private var task: Task<Void, Never>?

    init(pasteboard: any PasteboardReading,
         interval: Duration = .milliseconds(300),
         onChange: @escaping (PasteboardContents) -> Void) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.onChange = onChange
        // Don't capture whatever already happens to be on the pasteboard at launch.
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.poll()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Records the current `changeCount` as already seen — call right after writing to the
    /// pasteboard ourselves (paste/restore) so the resulting change isn't captured as a copy.
    func markSeen() {
        lastChangeCount = pasteboard.changeCount
    }

    /// A single poll tick (exposed for tests).
    func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        // R1: inspect declared types first; never read content for transient/concealed clips.
        guard PrivacyMarkers.decision(forTypeIdentifiers: pasteboard.typeIdentifiers()) == .record else {
            return
        }
        onChange(pasteboard.readContents())
    }
}
