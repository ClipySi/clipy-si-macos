//
//  PanelPreviewContentProvider.swift
//  ClipySi — Apple Silicon rewrite
//
//  Lazy, gated payload loading for the rich preview pane. Text / code / URL / color rows
//  need NOTHING from here: their `PanelRow.title` is already the masked display string. Only an
//  image row needs its blob decrypted (for the thumbnail), and file/PDF rows read just the
//  ciphertext FILE SIZE (zero decryption).
//
//  SECURITY (non-negotiable):
//  - A masked-secret row (`isSecret`) or an undecryptable row NEVER reaches the loader — no blob
//    decode for masked rows; reveal stays exclusively on the AuthGate paste path.
//  - Resolved plaintext (thumbnails) lives only in a tiny LRU (≤5) for the panel's open lifetime;
//    `clear()` is called from the controller's hide(), so nothing decoded outlives the panel.
//  - Decoded content is never logged or persisted.
//
//  Only the SELECTED row is resolved, debounced ~120ms behind selection changes so arrow-key
//  scrolling doesn't decrypt every row it passes. Loading runs in a background task (the loader is
//  nonisolated); results land back on the MainActor.
//

import AppKit
import Observation

@MainActor
@Observable
final class PanelPreviewContentProvider {
    /// Facts about the ORIGINAL image (the rendered thumbnail is downsampled), shown as the meta
    /// line under the image preview. Dimensions are nil when CGImageSource can't read the data.
    struct ImageMeta: Equatable, Sendable {
        let pixelWidth: Int?
        let pixelHeight: Int?
        /// Plaintext byte count of the original image data (not the ciphertext, not the thumbnail).
        let byteSize: Int
    }

    /// What the pane renders for a resolved row.
    enum Content: Equatable {
        case image(NSImage, meta: ImageMeta?)
        case fileInfo(byteSize: Int?)
    }

    /// What the loader returns across the actor boundary (Sendable payloads only; the NSImage is
    /// built on the MainActor from the already-downsampled data).
    enum LoadedPayload: Equatable, Sendable {
        case imageData(Data, meta: ImageMeta?)
        case fileInfo(byteSize: Int?)
    }

    typealias Loader = @Sendable (Clip.ID, PanelRow.ContentKind) async -> LoadedPayload?

    static let cacheLimit = 5
    static let debounceNanoseconds: UInt64 = 120_000_000

    /// A provider that never loads anything — the default for previews/tests.
    static let inert = PanelPreviewContentProvider { _, _ in nil }

    private let loader: Loader
    /// Tiny per-open LRU of resolved content. Cleared (with any pending load) by `clear()` on hide.
    private(set) var resolved: [Clip.ID: Content] = [:]
    private var order: [Clip.ID] = []
    /// The in-flight debounced load, if any — awaitable by tests.
    private(set) var pendingLoad: Task<Void, Never>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    /// The cached content for `row`, or nil (not an applicable row / not resolved yet). Reading is
    /// observation-tracked, so the pane re-renders when a load lands.
    func content(for row: PanelRow?) -> Content? {
        guard let row, case .clip(let id) = row.id, loadableKind(row) else { return nil }
        return resolved[id]
    }

    /// Resolve `row` (debounced). The guards are the security boundary: masked-secret and
    /// decrypt-failed rows never reach the loader, and only image/file/PDF kinds load at all.
    func request(_ row: PanelRow?) {
        pendingLoad?.cancel()
        pendingLoad = nil
        guard let row, case .clip(let id) = row.id,
              !row.isSecret, !row.decryptFailed, // masked rows: ZERO blob decode (reveal = AuthGate only)
              loadableKind(row),
              resolved[id] == nil else { return }
        let kind = row.contentKind
        pendingLoad = Task { [weak self, loader] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let payload = await loader(id, kind) else { return }
            guard !Task.isCancelled else { return }
            self?.store(id: id, payload: payload)
        }
    }

    /// Drop everything decoded and cancel any in-flight load — the controller's hide() hook, so no
    /// decrypted thumbnail outlives the panel being on screen.
    func clear() {
        pendingLoad?.cancel()
        pendingLoad = nil
        resolved.removeAll()
        order.removeAll()
    }

    // MARK: - Private

    /// Kinds that need a load: the image thumbnail (blob decrypt) and file/PDF size (file stat only).
    private func loadableKind(_ row: PanelRow) -> Bool {
        row.contentKind == .image || row.contentKind == .pdf || row.contentKind == .file
    }

    private func store(id: Clip.ID, payload: LoadedPayload) {
        let content: Content
        switch payload {
        case let .imageData(data, meta):
            guard let image = NSImage(data: data) else { return }
            content = .image(image, meta: meta)
        case .fileInfo(let byteSize):
            content = .fileInfo(byteSize: byteSize)
        }
        resolved[id] = content
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.cacheLimit, let oldest = order.first {
            order.removeFirst()
            resolved.removeValue(forKey: oldest)
        }
    }
}

// MARK: - Live loader

extension PanelPreviewContentProvider {
    /// AES-GCM overhead of a sealed blob (12-byte nonce + 16-byte tag) — subtracted so file sizes
    /// read as plaintext sizes.
    private nonisolated static let sealedOverhead = 28

    /// The production provider: image rows decrypt their primary blob and downsample to a thumbnail
    /// off the main actor; file/PDF rows stat the ciphertext file size (no decryption, no key use).
    static func live(blobStore: EncryptedBlobStore) -> PanelPreviewContentProvider {
        PanelPreviewContentProvider { id, kind in
            let clips = ClipRepository()
            guard let clip = try? clips.clip(id: id) else { return nil }
            switch kind {
            case .image:
                guard let data = try? blobStore.read(id: clip.dataPath) else { return nil }
                return .imageData(downsampledPNG(from: data) ?? data, meta: imageMeta(from: data))
            case .pdf:
                let size = blobStore.ciphertextSize(id: clip.dataPath)
                return .fileInfo(byteSize: size.map { max(0, $0 - sealedOverhead) })
            case .file:
                // A file clip's primary blob is the fileURL pasteboard REPRESENTATION (a few dozen
                // bytes of serialized URL), not the file contents — its size would mislabel every
                // file preview (adversarial review). No byte line for files.
                return .fileInfo(byteSize: nil)
            default:
                return nil
            }
        }
    }

    /// The original image's facts for the preview meta line: pixel dimensions read from the
    /// CGImageSource header (no decode) and the plaintext byte count.
    nonisolated static func imageMeta(from data: Data) -> ImageMeta {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        var width: Int?
        var height: Int?
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
        }
        return ImageMeta(pixelWidth: width, pixelHeight: height, byteSize: data.count)
    }

    /// A PNG thumbnail capped at `maxPixel` on the long edge, via CGImageSource (no full-size
    /// decode of giant images). Returns nil when the data isn't an image CGImageSource can read —
    /// the caller falls back to the original data.
    nonisolated static func downsampledPNG(from data: Data, maxPixel: Int = 640) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
