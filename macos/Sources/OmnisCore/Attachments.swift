import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A file attached to a message, already reduced to what the model can read:
/// a JPEG for a picture, or text for a document.
public struct Attachment: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case image, text }

    public let id: UUID
    public let kind: Kind
    public let name: String
    /// JPEG bytes, for an image.
    public let imageData: Data?
    /// The readable text, for a document.
    public let text: String?
    /// True if the file was longer than what is passed on.
    public let truncated: Bool

    public init(id: UUID = UUID(), kind: Kind, name: String, imageData: Data? = nil, text: String? = nil,
                truncated: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.imageData = imageData
        self.text = text
        self.truncated = truncated
    }
}

public enum AttachmentError: Error, Equatable, LocalizedError {
    case unsupported(String)
    case tooLarge(String)
    case unreadable(String)
    case empty(String)
    case tooMany

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\u{201C}\(name)\u{201D} is not a kind of file OMNIS can read yet. Images, PDFs and text files work."
        case .tooLarge(let name): return "\u{201C}\(name)\u{201D} is too large to attach."
        case .unreadable(let name): return "\u{201C}\(name)\u{201D} could not be read."
        case .empty(let name): return "\u{201C}\(name)\u{201D} has nothing in it to read."
        case .tooMany: return "Only \(AttachmentLoader.maxAttachments) files can be attached to one message."
        }
    }
}

/// Reads a file from disk and turns it into attachments. The app does this,
/// not the model: the model only ever sees what is produced here.
public enum AttachmentLoader {
    public static let maxAttachments = 4
    static let maxFileBytes = 30 * 1024 * 1024
    /// Longest side of an image passed to the model, in pixels.
    static let maxImagePixels = 1568
    static let maxTextCharacters = 60_000
    /// A scanned PDF has no text; this many of its pages are passed as pictures instead.
    static let maxScannedPages = 2

    public static func load(_ original: URL) throws -> [Attachment] {
        let name = original.lastPathComponent
        // Follow a shortcut to the real file first, so every check below is
        // about what would actually be read.
        let url = original.resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .contentTypeKey])
        guard values?.isDirectory != true else { throw AttachmentError.unsupported(name) }
        // Devices, pipes and the like are never read: they can be endless.
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw AttachmentError.unreadable(name) }
        guard size > 0 else { throw AttachmentError.empty(name) }
        guard size <= maxFileBytes else { throw AttachmentError.tooLarge(name) }

        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .pdf) {
            return try pdf(at: url, name: name)
        }
        if let type, type.conforms(to: .image) {
            return [try image(from: try read(url, name: name), name: name)]
        }
        // Anything else is accepted only if it really is text.
        let looksLikeText = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0 == .json
            || $0 == .xml || $0 == .yaml || $0 == .data || $0 == .item } ?? true
        guard looksLikeText, type?.conforms(to: .rtf) != true,
              let string = String(data: try read(url, name: name), encoding: .utf8), !string.contains("\u{0}") else {
            throw AttachmentError.unsupported(name)
        }
        return [try text(string, name: name)]
    }

    /// Reads a file, but never more than the size limit, whatever the file
    /// system said its size was.
    private static func read(_ url: URL, name: String) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AttachmentError.unreadable(name) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1) else { throw AttachmentError.unreadable(name) }
        guard data.count <= maxFileBytes else { throw AttachmentError.tooLarge(name) }
        return data
    }

    /// A picture from raw bytes, such as a pasted screenshot. Scaled down so
    /// its longest side is at most `maxImagePixels`, and stored as JPEG.
    public static func image(from data: Data, name: String) throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AttachmentError.unreadable(name)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour the camera's rotation
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(name)
        }
        return Attachment(kind: .image, name: name, imageData: try jpeg(scaled, name: name))
    }

    /// The largest JPEG that fits the message format once encoded as text.
    static let maxJPEGBytes = 4_400_000

    static func text(_ string: String, name: String) throws -> Attachment {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AttachmentError.empty(name) }
        guard trimmed.count > maxTextCharacters else {
            return Attachment(kind: .text, name: name, text: trimmed)
        }
        let note = "\n\n[The file is longer than this. Only the first part is included.]"
        return Attachment(kind: .text, name: name, text: String(trimmed.prefix(maxTextCharacters - note.count)) + note,
                          truncated: true)
    }

    private static func pdf(at url: URL, name: String) throws -> [Attachment] {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw AttachmentError.unreadable(name)
        }
        // Read page by page and stop once there is as much as will be used, so
        // a book-length PDF costs no more than a short one.
        var extracted = ""
        var pagesRead = 0
        while pagesRead < document.pageCount, extracted.count <= maxTextCharacters {
            if let page = document.page(at: pagesRead)?.string, !page.isEmpty {
                extracted += page + "\n"
            }
            pagesRead += 1
        }
        let cutShort = pagesRead < document.pageCount
        let readable = extracted.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        if readable >= 40 {
            let attachment = try text(extracted, name: name)
            guard cutShort, !attachment.truncated else { return [attachment] }
            let note = "\n\n[The file is longer than this. Only the first part is included.]"
            return [Attachment(kind: .text, name: name, text: (attachment.text ?? "") + note, truncated: true)]
        }
        // No text to speak of: a scan. Pass the first pages as pictures.
        var pages: [Attachment] = []
        for index in 0..<min(document.pageCount, maxScannedPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(maxImagePixels) / max(bounds.width, bounds.height, 1)
            let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            guard size.width >= 1, size.height >= 1,
                  let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            guard let rendered = context.makeImage() else { continue }
            let pageName = document.pageCount > 1 ? "\(name), page \(index + 1)" : name
            pages.append(Attachment(kind: .image, name: pageName, imageData: try jpeg(rendered, name: name),
                                    truncated: document.pageCount > maxScannedPages))
        }
        guard !pages.isEmpty else { throw AttachmentError.empty(name) }
        return pages
    }

    /// Flattens onto white (JPEG has no transparency) and encodes.
    private static func jpeg(_ image: CGImage, name: String, quality: Double = 0.82) throws -> Data {
        var flattened = image
        if let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            flattened = context.makeImage() ?? image
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadable(name)
        }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw AttachmentError.unreadable(name) }
        if output.length > maxJPEGBytes {
            // A very detailed picture: try once more, smaller, before giving up.
            guard quality > 0.5 else { throw AttachmentError.tooLarge(name) }
            return try jpeg(image, name: name, quality: 0.45)
        }
        return output as Data
    }
}

/// Decides what can be added to a message that may already hold files.
/// The model can only read so much at once, so the total text across all
/// documents is limited as well as the number of files.
public enum AttachmentLimits {
    /// The most document text one message may carry, across all its files.
    public static let maxTotalTextCharacters = 60_000
    /// Below this much room, a further document is refused, not cut to a stub.
    static let minimumUsefulCharacters = 2_000

    public struct Outcome: Equatable, Sendable {
        public var accepted: [Attachment]
        /// What to tell the user, if anything was cut or left out.
        public var note: String?
        /// True when nothing more can be added to this message.
        public var full: Bool
    }

    public static func fit(_ incoming: [Attachment], alongside existing: [Attachment]) -> Outcome {
        var accepted: [Attachment] = []
        var note: String?
        var count = existing.count
        var characters = existing.reduce(0) { $0 + ($1.text?.count ?? 0) }

        for attachment in incoming {
            guard count < AttachmentLoader.maxAttachments else {
                return Outcome(accepted: accepted, note: AttachmentError.tooMany.localizedDescription, full: true)
            }
            guard attachment.kind == .text, let text = attachment.text else {
                accepted.append(attachment)
                count += 1
                if attachment.truncated { note = "\u{201C}\(attachment.name)\u{201D} is long, so only its first pages will be read." }
                continue
            }
            let room = maxTotalTextCharacters - characters
            if text.count <= room {
                accepted.append(attachment)
                characters += text.count
                count += 1
                if attachment.truncated { note = "\u{201C}\(attachment.name)\u{201D} is long, so only the first part will be read." }
            } else if room >= minimumUsefulCharacters {
                let marker = "\n\n[The file is longer than this. Only the first part is included.]"
                let cut = String(text.prefix(room - marker.count)) + marker
                accepted.append(Attachment(id: attachment.id, kind: .text, name: attachment.name, text: cut, truncated: true))
                characters += cut.count
                count += 1
                note = "Together these files are more than can be read at once, so only the first part of \u{201C}\(attachment.name)\u{201D} will be read."
            } else {
                note = "\u{201C}\(attachment.name)\u{201D} was left out: the files already attached are as much as can be read at once."
            }
        }
        return Outcome(accepted: accepted, note: note, full: count >= AttachmentLoader.maxAttachments)
    }
}
