import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OmnisCore

/// Makes small test files so no test depends on a file that might not exist.
enum Make {
    static func bitmap(width: Int, height: Int, alpha: Bool = false,
                       draw: (CGContext) -> Void) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        draw(context)
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        png(bitmap(width: width, height: height) { context in
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        })
    }

    /// A PDF whose pages are drawn by `draw`. With text drawn through Core Text it has real, selectable text.
    static func pdf(at url: URL, pages: Int, draw: (CGContext, Int) -> Void) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0..<pages {
            context.beginPDFPage(nil)
            draw(context, page)
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func write(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat = 14) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    static func pixelSize(ofJPEG data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func isJPEG(_ data: Data) -> Bool { data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) }
}

@Suite struct AttachmentLoaderTests {
    @Test func aLargePictureIsScaledDownAndStoredAsJPEG() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("big photo.png")
        try Make.solid(width: 4000, height: 2000, red: 0.2, green: 0.4, blue: 0.9).write(to: file)
        let attachments = try AttachmentLoader.load(file)
        #expect(attachments.count == 1)
        let attachment = attachments[0]
        #expect(attachment.kind == .image)
        #expect(attachment.name == "big photo.png")
        let data = try #require(attachment.imageData)
        #expect(Make.isJPEG(data))
        let size = try #require(Make.pixelSize(ofJPEG: data))
        #expect(size.width == 1568)
        #expect(size.height == 784)             // proportions kept
        #expect(data.count < 1_000_000)
    }

    @Test func aSmallPictureIsNotEnlarged() throws {
        let attachment = try AttachmentLoader.image(from: Make.solid(width: 300, height: 200, red: 1, green: 0, blue: 0),
                                                    name: "Pasted image")
        let jpeg = try #require(attachment.imageData)
        let size = try #require(Make.pixelSize(ofJPEG: jpeg))
        #expect(size.width == 300 && size.height == 200)
    }

    @Test func transparentAreasBecomeWhiteNotBlack() throws {
        let clear = Make.png(Make.bitmap(width: 100, height: 100, alpha: true) { _ in })   // fully transparent
        let attachment = try AttachmentLoader.image(from: clear, name: "logo.png")
        let jpeg = try #require(attachment.imageData)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let probe = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        probe.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = probe.data!.assumingMemoryBound(to: UInt8.self)
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
    }

    @Test func aPDFWithTextIsReadAsText() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("report.pdf")
        Make.pdf(at: file, pages: 2) { context, page in
            Make.write("Quarterly report page \(page + 1): revenue rose to 77 million in the fourth quarter.",
                       in: context, at: CGPoint(x: 72, y: 700))
        }
        let attachments = try AttachmentLoader.load(file)
        #expect(attachments.count == 1)
        #expect(attachments[0].kind == .text)
        let text = try #require(attachments[0].text)
        #expect(text.contains("revenue rose to 77 million"))
        #expect(text.contains("page 2"))
        #expect(!attachments[0].truncated)
    }

    @Test func aScannedPDFWithNoTextBecomesPicturesOfItsFirstPages() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("scan.pdf")
        Make.pdf(at: file, pages: 5) { context, _ in
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 100, y: 300, width: 400, height: 200))   // shapes only, no text
        }
        let attachments = try AttachmentLoader.load(file)
        #expect(attachments.count == 2)
        #expect(attachments.allSatisfy { $0.kind == .image && $0.truncated })
        #expect(attachments.map(\.name) == ["scan.pdf, page 1", "scan.pdf, page 2"])
        let firstPage = try #require(attachments[0].imageData)
        let size = try #require(Make.pixelSize(ofJPEG: firstPage))
        #expect(max(size.width, size.height) == 1568)
    }

    @Test func textAndCodeFilesAreReadAndLongOnesAreCutWithANote() throws {
        let scratch = try Scratch()
        let notes = try scratch.file("notes.md", contents: "  # Title\n\nSome notes.\n\n")
        #expect(try AttachmentLoader.load(notes)[0].text == "# Title\n\nSome notes.")
        let code = try scratch.file("main.swift", contents: "print(\"hi\")\n")
        #expect(try AttachmentLoader.load(code)[0].kind == .text)

        let long = try scratch.file("long.txt", contents: String(repeating: "word ", count: 30_000))
        let cut = try AttachmentLoader.load(long)[0]
        #expect(cut.truncated)
        #expect((cut.text ?? "").count <= 60_000)
        #expect((cut.text ?? "").hasSuffix("[The file is longer than this. Only the first part is included.]"))
    }

    @Test func thingsThatCannotBeReadAreRefusedWithAReason() throws {
        let scratch = try Scratch()
        func failure(_ url: URL) -> AttachmentError? {
            do { _ = try AttachmentLoader.load(url); return nil } catch { return error as? AttachmentError }
        }
        let binary = scratch.url.appendingPathComponent("program.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x7F]).write(to: binary)
        #expect(failure(binary) == .unsupported("program.bin"))

        let empty = try scratch.file("empty.txt", contents: "")
        #expect(failure(empty) == .empty("empty.txt"))
        let blank = try scratch.file("blank.txt", contents: "   \n\n ")
        #expect(failure(blank) == .empty("blank.txt"))

        #expect(failure(try scratch.folder("a-folder")) == .unsupported("a-folder"))
        #expect(failure(scratch.url.appendingPathComponent("missing.png")) == .unreadable("missing.png"))

        let fake = scratch.url.appendingPathComponent("not-really.png")
        try Data("this is not a picture".utf8).write(to: fake)
        #expect(failure(fake) == .unreadable("not-really.png"))

        let brokenPDF = scratch.url.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4 nonsense".utf8).write(to: brokenPDF)
        #expect(failure(brokenPDF) == .unreadable("broken.pdf"))

        #expect(AttachmentError.tooMany.localizedDescription == "Only 4 files can be attached to one message.")
    }
}

@Suite struct AttachmentConversationTests {
    let picture = Attachment(kind: .image, name: "chart.png", imageData: Data([0xFF, 0xD8, 0xFF, 0x00]))
    let notes = Attachment(kind: .text, name: "notes.txt", text: "body")

    @Test func onlyTheMostRecentFilesTravelWithLaterQuestions() {
        var chat = Conversation()
        var id = chat.begin(question: "what is this?", attachments: [picture])
        chat.update(id) { $0.text = "A chart."; $0.state = .done }
        id = chat.begin(question: "and this?", attachments: [notes])
        chat.update(id) { $0.text = "Notes."; $0.state = .done }
        id = chat.begin(question: "thanks")
        chat.update(id) { $0.text = "Welcome."; $0.state = .done }

        let history = chat.history()
        #expect(history.map(\.attachments.count) == [0, 0, 1, 0, 0, 0])
        #expect(history[2].attachments == [notes])
        #expect(history[0].content == "what is this?")   // the words stay, the file does not
    }

    @Test func aChatThatHasHadAFileStaysLocalAndOfflineEvenAfterTheFileLeavesTheHistory() {
        var chat = Conversation()
        #expect(!chat.hasFiles && !chat.staysLocal)
        var id = chat.begin(question: "read this", attachments: [notes])
        #expect(chat.hasFiles && chat.staysLocal)   // set at once, even before any answer
        chat.update(id) { $0.text = "It says: body."; $0.state = .done }

        // Enough later turns to push the file's turn out of what is sent along.
        for index in 0..<15 {
            id = chat.begin(question: "follow-up \(index)")
            chat.update(id) { $0.text = "answer \(index)"; $0.state = .done }
        }
        #expect(chat.history().allSatisfy { $0.attachments.isEmpty })
        #expect(chat.hasFiles && chat.staysLocal)   // the app still remembers

        chat.clear()
        #expect(!chat.hasFiles && !chat.staysLocal)
    }

    @Test func aFileOnAFailedQuestionStillMarksTheChat() {
        var chat = Conversation()
        let id = chat.begin(question: "read this", attachments: [notes])
        chat.update(id) { $0.state = .failed("model stopped") }
        #expect(chat.history().isEmpty)
        #expect(chat.hasFiles && chat.staysLocal)
    }

    @Test func aFileOnAFailedQuestionIsNotSentAgain() {
        var chat = Conversation()
        let id = chat.begin(question: "read this", attachments: [notes])
        chat.update(id) { $0.state = .failed("model stopped") }
        #expect(chat.history().isEmpty)
        #expect(chat.messages[0].attachments == [notes])   // still shown in the window
    }

    @Test func attachmentsAreEncodedForTheBackend() throws {
        let data = try ProtocolCodec.encode(.ask(id: "q", text: "look", history: [
            ChatTurn(role: .user, content: "earlier", attachments: [notes]),
            ChatTurn(role: .assistant, content: "seen"),
        ], attachments: [picture, notes]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(object["attachments"] as? [[String: String]])
        #expect(sent == [
            ["kind": "image", "name": "chart.png", "data": Data([0xFF, 0xD8, 0xFF, 0x00]).base64EncodedString()],
            ["kind": "text", "name": "notes.txt", "text": "body"],
        ])
        let history = try #require(object["history"] as? [[String: Any]])
        #expect((history[0]["attachments"] as? [[String: String]])?.first?["name"] == "notes.txt")
        #expect(history[1]["attachments"] == nil)
    }
}
