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

    public static func load(_ url: URL) throws -> [Attachment] {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
        guard values?.isDirectory != true else { throw AttachmentError.unsupported(name) }
        guard let size = values?.fileSize else { throw AttachmentError.unreadable(name) }
        guard size > 0 else { throw AttachmentError.empty(name) }
        guard size <= maxFileBytes else { throw AttachmentError.tooLarge(name) }

        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .pdf) {
            return try pdf(at: url, name: name)
        }
        if let type, type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
            return [try image(from: data, name: name)]
        }
        // Anything else is accepted only if it really is text.
        let looksLikeText = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0 == .json
            || $0 == .xml || $0 == .yaml || $0 == .data || $0 == .item } ?? true
        guard looksLikeText, let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8), !string.contains("\u{0}") else {
            throw AttachmentError.unsupported(name)
        }
        return [try text(string, name: name)]
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
        let extracted = document.string ?? ""
        let readable = extracted.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        if readable >= 40 {
            return [try text(extracted, name: name)]
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
    private static func jpeg(_ image: CGImage, name: String) throws -> Data {
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
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw AttachmentError.unreadable(name) }
        return output as Data
    }
}
