//
//  Attachment.swift
//  osaurus
//
//  Unified attachment model for images and documents in chat messages.
//
//  Primary `Kind` cases:
//    - `.image(Data)` — raw image bytes, surfaced to the model as an
//      image input.
//    - `.document(filename, content, fileSize)` — the legacy text-only
//      shape. Still produced for formats where the registry has no
//      adapter (or the adapter returns a `PlainTextRepresentation`).
//    - `.structuredDocument(StructuredDocument)` — typed document
//      preserving the format-native representation (`Workbook`,
//      `PDFDocumentRepresentation`, `CSVTable`, …). Agent tools that
//      understand the representation pull the typed value through
//      `attachment.structuredDocument`; everything else falls back to
//      the text view via `documentContent`.
//    - `.imageRef` / `.documentRef` — encrypted spillover references for
//      large persisted attachments.
//
//  Codable: `.structuredDocument` serialises as `.document` on the wire
//  so persisted chat history stays compatible with older builds. The
//  typed structure is rebuilt in-memory on every new file ingest (chat
//  attachment, drop / paste); persistence intentionally does not
//  round-trip it because the format-native representation is derived
//  from the source bytes.
//

import Foundation

public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: Kind

    public enum Kind: Codable, @unchecked Sendable, Equatable {
        case image(Data)
        case document(filename: String, content: String, fileSize: Int)
        case structuredDocument(StructuredDocument)

        /// Audio bytes + format hint (e.g. "wav", "mp3", "m4a", "flac",
        /// "ogg"). Format flows into `MessageContentPart.audioInput.format`
        /// and onto the temp-file extension that drives vmlx's
        /// AVAudioConverter dispatch (`materializeMediaDataUrl`).
        /// Only routed for models whose `ModelMediaCapabilities` advertise
        /// audio support — `FloatingInputCard` rejects audio attachments
        /// for non-audio models at drop time.
        case audio(Data, format: String, filename: String?)

        /// Video bytes. Container format inferred from filename
        /// extension (mp4 / mov / m4v / webm). Routed only for models
        /// advertising video support.
        case video(Data, filename: String?)

        /// Spillover variant: image bytes have been written to
        /// `AttachmentBlobStore` (encrypted) and only a content-address
        /// hash + size live in the chat-history JSON column.
        /// Created by `AttachmentBlobStore.spillIfNeeded`.
        case imageRef(hash: String, byteCount: Int)

        /// Spillover variant: document `content` text has been written
        /// to `AttachmentBlobStore` (encrypted). `fileSize` is the
        /// original on-disk size; `hash` indexes the encrypted blob.
        case documentRef(filename: String, hash: String, fileSize: Int)

        /// Spillover variant: audio bytes spilled to encrypted blob store.
        case audioRef(hash: String, byteCount: Int, format: String, filename: String?)

        /// Spillover variant: video bytes spilled to encrypted blob store.
        case videoRef(hash: String, byteCount: Int, filename: String?)

        private enum CodingKeys: String, CodingKey {
            case type, data, filename, content, fileSize, hash, byteCount, format
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let data):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
            case .document(let filename, let content, let fileSize):
                try container.encode("document", forKey: .type)
                try container.encode(filename, forKey: .filename)
                try container.encode(content, forKey: .content)
                try container.encode(fileSize, forKey: .fileSize)
            case .structuredDocument(let document):
                // Downgrade to the legacy `document` wire shape so
                // persisted history stays readable by older builds.
                try container.encode("document", forKey: .type)
                try container.encode(document.filename, forKey: .filename)
                try container.encode(document.textFallback, forKey: .content)
                try container.encode(Int(document.fileSize), forKey: .fileSize)
            case .audio(let data, let format, let filename):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(format, forKey: .format)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .video(let data, let filename):
                try container.encode("video", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .imageRef(let hash, let byteCount):
                try container.encode("image_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
            case .documentRef(let filename, let hash, let fileSize):
                try container.encode("document_ref", forKey: .type)
                try container.encode(filename, forKey: .filename)
                try container.encode(hash, forKey: .hash)
                try container.encode(fileSize, forKey: .fileSize)
            case .audioRef(let hash, let byteCount, let format, let filename):
                try container.encode("audio_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
                try container.encode(format, forKey: .format)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .videoRef(let hash, let byteCount, let filename):
                try container.encode("video_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
                try container.encodeIfPresent(filename, forKey: .filename)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "image":
                let data = try container.decode(Data.self, forKey: .data)
                self = .image(data)
            case "document":
                let filename = try container.decode(String.self, forKey: .filename)
                let content = try container.decode(String.self, forKey: .content)
                let fileSize = try container.decode(Int.self, forKey: .fileSize)
                self = .document(filename: filename, content: content, fileSize: fileSize)
            case "audio":
                let data = try container.decode(Data.self, forKey: .data)
                let format = try container.decode(String.self, forKey: .format)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .audio(data, format: format, filename: filename)
            case "video":
                let data = try container.decode(Data.self, forKey: .data)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .video(data, filename: filename)
            case "image_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                self = .imageRef(hash: hash, byteCount: byteCount)
            case "document_ref":
                let filename = try container.decode(String.self, forKey: .filename)
                let hash = try container.decode(String.self, forKey: .hash)
                let fileSize = try container.decode(Int.self, forKey: .fileSize)
                self = .documentRef(filename: filename, hash: hash, fileSize: fileSize)
            case "audio_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                let format = try container.decode(String.self, forKey: .format)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .audioRef(hash: hash, byteCount: byteCount, format: format, filename: filename)
            case "video_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .videoRef(hash: hash, byteCount: byteCount, filename: filename)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown attachment type: \(type)"
                )
            }
        }

        public static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.image(let a), .image(let b)):
                return a == b
            case (.document(let f1, let c1, let s1), .document(let f2, let c2, let s2)):
                return f1 == f2 && c1 == c2 && s1 == s2
            case (.structuredDocument(let a), .structuredDocument(let b)):
                return a.filename == b.filename
                    && a.textFallback == b.textFallback
                    && a.fileSize == b.fileSize
                    && a.formatId == b.formatId
            case (.audio(let aData, let aFormat, let aFilename), .audio(let bData, let bFormat, let bFilename)):
                return aData == bData && aFormat == bFormat && aFilename == bFilename
            case (.video(let aData, let aFilename), .video(let bData, let bFilename)):
                return aData == bData && aFilename == bFilename
            case (.imageRef(let aHash, let aByteCount), .imageRef(let bHash, let bByteCount)):
                return aHash == bHash && aByteCount == bByteCount
            case (
                .documentRef(let aFilename, let aHash, let aFileSize),
                .documentRef(let bFilename, let bHash, let bFileSize)
            ):
                return aFilename == bFilename && aHash == bHash && aFileSize == bFileSize
            case (
                .audioRef(let aHash, let aByteCount, let aFormat, let aFilename),
                .audioRef(let bHash, let bByteCount, let bFormat, let bFilename)
            ):
                return aHash == bHash && aByteCount == bByteCount && aFormat == bFormat && aFilename == bFilename
            case (
                .videoRef(let aHash, let aByteCount, let aFilename),
                .videoRef(let bHash, let bByteCount, let bFilename)
            ):
                return aHash == bHash && aByteCount == bByteCount && aFilename == bFilename
            default:
                return false
            }
        }
    }

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    // MARK: - Factory Methods

    public static func image(_ data: Data) -> Attachment {
        Attachment(kind: .image(data))
    }

    public static func document(filename: String, content: String, fileSize: Int) -> Attachment {
        Attachment(kind: .document(filename: filename, content: content, fileSize: fileSize))
    }

    public static func structuredDocument(_ document: StructuredDocument) -> Attachment {
        Attachment(kind: .structuredDocument(document))
    }

    public static func audio(_ data: Data, format: String, filename: String? = nil) -> Attachment {
        Attachment(kind: .audio(data, format: format, filename: filename))
    }

    public static func video(_ data: Data, filename: String? = nil) -> Attachment {
        Attachment(kind: .video(data, filename: filename))
    }

    // MARK: - Queries

    public var isImage: Bool {
        switch kind {
        case .image, .imageRef: return true
        default: return false
        }
    }

    /// True for both the legacy `.document(…)` case and the new
    /// `.structuredDocument(…)` case. Callers that only need the text
    /// view can stay on this check + `documentContent`.
    public var isDocument: Bool {
        switch kind {
        case .document, .documentRef, .structuredDocument: return true
        default: return false
        }
    }

    public var isAudio: Bool {
        switch kind {
        case .audio, .audioRef: return true
        default: return false
        }
    }

    public var isVideo: Bool {
        switch kind {
        case .video, .videoRef: return true
        default: return false
        }
    }

    /// Returns inline image bytes if present. For `imageRef` variants
    /// you must hydrate via `AttachmentBlobStore.read(hash)`. Use
    /// `loadImageData()` for a unified accessor that lazily resolves
    /// either case.
    public var imageData: Data? {
        if case .image(let data) = kind { return data }
        return nil
    }

    public var filename: String? {
        switch kind {
        case .document(let name, _, _), .documentRef(let name, _, _):
            return name
        case .structuredDocument(let doc):
            return doc.filename
        case .audio(_, _, let name), .audioRef(_, _, _, let name),
            .video(_, let name), .videoRef(_, _, let name):
            return name
        default:
            return nil
        }
    }

    /// Audio format hint ("wav" / "mp3" / "m4a" / etc.). The host uses
    /// this both for display and to populate `MessageContentPart.audioInput.format`,
    /// which becomes the temp-file extension that drives vmlx's
    /// AVAudioConverter dispatch (`materializeMediaDataUrl`'s audio
    /// canonicalization table — see PR #967 audit-fix).
    public var audioFormat: String? {
        switch kind {
        case .audio(_, let format, _), .audioRef(_, _, let format, _):
            return format
        default:
            return nil
        }
    }

    public var documentContent: String? {
        switch kind {
        case .document(_, let content, _): return content
        case .structuredDocument(let doc): return doc.textFallback
        default: return nil
        }
    }

    /// The typed representation, present only for `.structuredDocument`.
    /// Agent tools that know how to consume a `Workbook` /
    /// `PDFDocumentRepresentation` / `CSVTable` downcast
    /// `structuredDocument?.representation.underlying` to the concrete
    /// type. Every other consumer should keep using `documentContent`.
    public var structuredDocument: StructuredDocument? {
        if case .structuredDocument(let doc) = kind { return doc }
        return nil
    }

    /// Resolves the attachment to its raw image bytes — inline or
    /// hydrated from the blob store. Returns `nil` for non-image kinds
    /// or read failures.
    public func loadImageData() -> Data? {
        switch kind {
        case .image(let data):
            return data
        case .imageRef(let hash, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its raw audio bytes — inline or
    /// hydrated from the encrypted blob store. Returns `nil` for non-audio
    /// kinds or read failures.
    ///
    /// Memory note: audio attachments are eligible for spillover via
    /// `AttachmentBlobStore.spillIfNeeded` so chat-history JSON columns
    /// don't bloat with raw PCM. A 30-second wav at 16 kHz mono is
    /// ~960 KB inline; spillover writes the bytes to an encrypted blob
    /// keyed by content-hash and persists only the hash inline.
    public func loadAudioData() -> Data? {
        switch kind {
        case .audio(let data, _, _):
            return data
        case .audioRef(let hash, _, _, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its raw video bytes — inline or
    /// hydrated from the encrypted blob store.
    ///
    /// Memory note: video attachments are heavyweight — even a 1-min mp4
    /// is typically ~30 MB. Always use spillover (`AttachmentBlobStore.
    /// spillIfNeeded`) for video; never inline more than a frame
    /// thumbnail in chat-history JSON.
    public func loadVideoData() -> Data? {
        switch kind {
        case .video(let data, _):
            return data
        case .videoRef(let hash, _, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its document content text — inline or
    /// hydrated from the blob store. Returns `nil` for non-document
    /// kinds or read failures.
    public func loadDocumentContent() -> String? {
        switch kind {
        case .document(_, let content, _):
            return content
        case .structuredDocument(let doc):
            return doc.textFallback
        case .documentRef(_, let hash, _):
            return (try? AttachmentBlobStore.read(hash)).flatMap { String(data: $0, encoding: .utf8) }
        default:
            return nil
        }
    }

    // MARK: - Display Helpers

    public var fileSizeFormatted: String? {
        switch kind {
        case .document(_, _, let size), .documentRef(_, _, let size):
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        case .structuredDocument(let doc):
            return ByteCountFormatter.string(fromByteCount: doc.fileSize, countStyle: .file)
        case .audio(let data, _, _):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .video(let data, _):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .audioRef(_, let byteCount, _, _), .videoRef(_, let byteCount, _):
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        default:
            return nil
        }
    }

    public var fileExtension: String? {
        guard let name = filename else { return nil }
        return (name as NSString).pathExtension.lowercased()
    }

    public var fileIcon: String {
        if isAudio { return "waveform" }
        if isVideo { return "film" }
        guard let ext = fileExtension else { return "photo" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text"
        case "md", "markdown": return "text.document"
        case "csv", "tsv", "xlsx", "xls", "ods": return "tablecells"
        case "json": return "curlybraces"
        case "xml", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "rtf": return "doc.richtext"
        default: return "doc.plaintext"
        }
    }

    /// Estimated token count for context budget calculations.
    ///
    /// Empirical baselines from OmniBench / vmlx:
    /// - Image: ~256 vision tokens/frame after spatial-merge 2×2
    /// - Audio: Parakeet emits ~50 acoustic tokens/sec at 16 kHz mono,
    ///   so 1 byte ≈ (1 sec / 32k bytes) × 50 = ~0.0016 tokens/byte
    /// - Video: ~256 vision tokens × frame_count, where vmlx samples
    ///   8 frames default → ~2K vision tokens/clip regardless of duration
    ///
    /// These are approximations for budget gating. The real token count
    /// is determined by the model's processor at decode time.
    public var estimatedTokens: Int {
        switch kind {
        case .image(let data):
            return max(1, (data.count * 4) / 3 / 4)
        case .imageRef(_, let byteCount):
            return max(1, (byteCount * 4) / 3 / 4)
        case .document(_, let content, _):
            return max(1, content.count / 4)
        case .documentRef(_, _, let fileSize):
            return max(1, fileSize / 4)
        case .structuredDocument(let doc):
            return max(1, doc.textFallback.count / 4)
        case .audio(let data, _, _):
            // ~50 acoustic tokens/sec @ 16kHz mono → ~1 token / 640 bytes
            return max(1, data.count / 640)
        case .audioRef(_, let byteCount, _, _):
            return max(1, byteCount / 640)
        case .video, .videoRef:
            // Bounded ~2K tokens regardless of file size (8 frames × 256 tokens)
            return 2048
        }
    }

    // MARK: - Spillover hooks (memory + disk-cache integration)

    /// Threshold above which inline payloads SHOULD spill to encrypted
    /// blob storage. Mirrors the existing image-spill policy and keeps
    /// chat-history JSON columns bounded.
    ///
    /// Audio threshold is lower (256 KB) because chat-history is read
    /// often and a single 5-min wav (~9.6 MB) read on every history
    /// open would tax the SQLite page cache.
    ///
    /// Video threshold is even lower (64 KB) — virtually all real video
    /// attachments will spill. The inline path exists only for
    /// in-memory request lifetimes; persistence always goes via
    /// `AttachmentBlobStore.spillIfNeeded`.
    public static let audioSpillThresholdBytes = 256 * 1024
    public static let videoSpillThresholdBytes = 64 * 1024
}

// MARK: - Array Helpers

extension Array where Element == Attachment {
    /// Inline image bytes only. For spilled `imageRef` attachments use
    /// `loadImages()` to hydrate from the blob store.
    public var images: [Data] {
        compactMap(\.imageData)
    }

    /// Resolve every image attachment (inline + spilled) into its raw
    /// bytes. Performs blocking disk reads for spilled blobs — call
    /// off the main thread for chats with many attachments.
    public func loadImages() -> [Data] {
        compactMap { $0.loadImageData() }
    }

    public var documents: [Attachment] {
        filter(\.isDocument)
    }

    public var audios: [Attachment] {
        filter(\.isAudio)
    }

    public var videos: [Attachment] {
        filter(\.isVideo)
    }

    public var hasImages: Bool {
        contains(where: \.isImage)
    }

    public var hasDocuments: Bool {
        contains(where: \.isDocument)
    }

    public var hasAudios: Bool {
        contains(where: \.isAudio)
    }

    public var hasVideos: Bool {
        contains(where: \.isVideo)
    }
}
