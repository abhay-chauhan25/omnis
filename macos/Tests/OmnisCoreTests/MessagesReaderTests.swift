import Foundation
import SQLite3
import Testing
@testable import MessagesReaderCore
@testable import OmnisHelperLink

/// A made-up Messages database with the same tables the real one has.
final class FakeMessages {
    let path: String
    private var database: OpaquePointer?
    private var nextMessage: Int64 = 1

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-messages-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.appendingPathComponent("chat.db").path
        sqlite3_open(path, &database)
        run("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, style INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER,
                                  handle_id INTEGER, associated_message_type INTEGER DEFAULT 0);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO handle VALUES (1, '+15550001'), (2, 'sam@example.com');
            INSERT INTO chat VALUES (1, '+15550001', '', 45), (2, 'chat99', 'Flat', 43);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
            """)
    }

    deinit { sqlite3_close(database) }

    func run(_ sql: String) {
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &message) != SQLITE_OK { fatalError(String(cString: message!)) }
    }

    /// Adds a message. With `packed`, the words go in the archived form and the plain column is left empty.
    func add(chat: Int, from handle: Int?, _ text: String, at time: String, packed: Bool = false, reaction: Bool = false) {
        let date = MessageStore.stored(ISO8601DateFormatter().date(from: time)!)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "INSERT INTO message VALUES (?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, nextMessage)
        if packed {
            sqlite3_bind_null(statement, 2)
            let blob = NSArchiver.archivedData(withRootObject: NSMutableAttributedString(string: text))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        } else {
            sqlite3_bind_text(statement, 2, text, -1, transient)
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, date)
        sqlite3_bind_int64(statement, 5, handle == nil ? 1 : 0)
        sqlite3_bind_int64(statement, 6, Int64(handle ?? 0))
        sqlite3_bind_int64(statement, 7, reaction ? 2000 : 0)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        run("INSERT INTO chat_message_join VALUES (\(chat), \(nextMessage))")
        nextMessage += 1
    }
}

@Suite struct TypedStreamTests {
    func packed(_ text: String, mutable: Bool = true) -> Data {
        NSArchiver.archivedData(withRootObject: mutable ? NSMutableAttributedString(string: text) : NSAttributedString(string: text))
    }

    @Test func theWordsAreFoundInWhatMessagesStores() {
        #expect(TypedStream.text(from: packed("See you at 6")) == "See you at 6")
        #expect(TypedStream.text(from: packed("See you at 6", mutable: false)) == "See you at 6")
        #expect(TypedStream.text(from: packed("Caf\u{00E9} \u{1F600} ok")) == "Caf\u{00E9} \u{1F600} ok")
        let long = String(repeating: "word ", count: 60)                    // longer than one length byte can say
        #expect(TypedStream.text(from: packed(long)) == long)
        let huge = String(repeating: "x", count: 70_000)                   // longer than two can say
        #expect(TypedStream.text(from: packed(huge)) == huge)
        // Text that names the marker itself does not confuse it.
        #expect(TypedStream.text(from: packed("NSString + NSString")) == "NSString + NSString")
    }

    @Test func damagedOrHostileDataGivesNothingAndNeverCrashes() {
        #expect(TypedStream.text(from: Data()) == nil)
        #expect(TypedStream.text(from: Data("not an archive at all".utf8)) == nil)
        let good = packed("Hello there, this is a message")
        // Cut short at every length, and with every byte flipped in turn.
        for count in 0..<good.count { _ = TypedStream.text(from: good.prefix(count)) }
        for index in 0..<good.count {
            var bad = good
            bad[index] ^= 0xFF
            _ = TypedStream.text(from: bad)
        }
        // A length that claims more than is there.
        var lying = [UInt8]("xxxxxxxxNSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x82, 0xFF, 0xFF, 0xFF, 0x7F] + [UInt8]("hi".utf8)
        #expect(TypedStream.text(from: Data(lying)) == nil)
        lying[lying.count - 7] = 0x81
        #expect(TypedStream.text(from: Data(lying)) == nil)
    }
}

@Suite struct MessageStoreTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!

    func filled() -> FakeMessages {
        let fake = FakeMessages()
        fake.add(chat: 1, from: 1, "Are we still on for Friday?", at: "2026-11-23T09:00:00Z")
        fake.add(chat: 1, from: nil, "Yes, 6pm at the usual place", at: "2026-11-23T09:05:00Z", packed: true)
        fake.add(chat: 1, from: 1, "Loved", at: "2026-11-23T09:06:00Z", reaction: true)
        fake.add(chat: 2, from: 2, "Rent is due on Friday", at: "2026-11-24T08:00:00Z", packed: true)
        fake.add(chat: 1, from: 1, "An old one", at: "2025-01-01T00:00:00Z")
        return fake
    }

    @Test func conversationsAreListedNewestFirstWithTheirPeople() throws {
        let fake = filled()
        let chats = try MessageStore(path: fake.path).chats(limit: 10)
        #expect(chats.map(\.id) == ["chat99", "+15550001"])
        #expect(chats[0].name == "Flat" && chats[0].group && chats[0].people == ["+15550001", "sam@example.com"])
        #expect(!chats[1].group && chats[1].people == ["+15550001"])
        #expect(chats[0].last == ISO8601DateFormatter().date(from: "2026-11-24T08:00:00Z")!.timeIntervalSince1970)
    }

    @Test func aConversationIsReadOldestFirstWithoutReactionsOrOldMessages() throws {
        let fake = filled()
        let messages = try MessageStore(path: fake.path).messages(chat: "+15550001", days: 30, limit: 50, now: Self.now)
        #expect(messages.map(\.text) == ["Are we still on for Friday?", "Yes, 6pm at the usual place"])
        #expect(messages.map(\.fromMe) == [false, true] && messages.map(\.sender) == ["+15550001", ""])
        // The newest are kept when there are more than asked for.
        #expect(try MessageStore(path: fake.path).messages(chat: "+15550001", days: 30, limit: 1, now: Self.now).map(\.text) == ["Yes, 6pm at the usual place"])
        #expect(try MessageStore(path: fake.path).messages(chat: "nobody", days: 30, limit: 50, now: Self.now).isEmpty)
    }

    @Test func searchFindsWordsInBothFormsAndTreatsThemAsWords() throws {
        let fake = filled()
        let store = try MessageStore(path: fake.path)
        #expect(try store.search(text: "friday", days: 30, limit: 10, now: Self.now).map(\.text) == ["Rent is due on Friday", "Are we still on for Friday?"])
        #expect(try store.search(text: "usual PLACE", days: 30, limit: 10, now: Self.now).count == 1)
        #expect(try store.search(text: "old", days: 30, limit: 10, now: Self.now).isEmpty)        // too long ago
        // Nothing typed is ever part of the question put to the database.
        #expect(try store.search(text: "%' OR 1=1 --", days: 30, limit: 10, now: Self.now).isEmpty)
        #expect(try store.messages(chat: "' OR '1'='1", days: 30, limit: 10, now: Self.now).isEmpty)
    }

    @Test func theDatabaseCannotBeChangedAndLimitsHold() throws {
        let fake = FakeMessages()
        for index in 0..<80 { fake.add(chat: 1, from: 1, String(repeating: "long ", count: 400) + "\(index)", at: "2026-11-24T10:00:00Z") }
        let store = try MessageStore(path: fake.path)
        let messages = try store.messages(chat: "+15550001", days: 100_000, limit: 100_000, now: Self.now)
        #expect(messages.count == MessageStore.maxMessages)
        #expect(messages.allSatisfy { $0.text.count == MessageStore.maxTextCharacters })
        // The file is opened for reading only.
        var handle: OpaquePointer?
        sqlite3_open_v2(fake.path, &handle, SQLITE_OPEN_READONLY, nil)
        #expect(sqlite3_exec(handle, "DELETE FROM message", nil, nil, nil) != SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: StoreError.self) { try MessageStore(path: "/nonexistent/folder/chat.db") }
    }

    @Test func aMessageIsCutToSizeAndHiddenCharactersAreDropped() throws {
        // Marks stacked on one letter: few characters, very many bytes.
        let stacked = "a" + String(repeating: "\u{0301}", count: 50_000) + " end"
        let tidy = MessageStore.tidy(stacked)
        #expect(tidy.utf8.count <= MessageStore.maxTextBytes && tidy.hasSuffix(" end"))
        #expect(MessageStore.tidy(String(repeating: "\u{1F600}", count: 5_000)).utf8.count <= MessageStore.maxTextBytes)
        // Characters that reorder or hide text, and controls, do not come through. Line breaks do.
        #expect(MessageStore.tidy("pay\u{202E}eeffoc\u{202C} now\u{200B}\u{0007}\nok") == "payeeffoc now\nok")
        #expect(MessageStore.tidy("Caf\u{00E9} \u{1F600}") == "Caf\u{00E9} \u{1F600}")
    }

    @Test func messagesSetForLaterAndEmptyOnesAreNotListed() throws {
        let fake = FakeMessages()
        fake.add(chat: 1, from: nil, "Happy birthday", at: "2026-11-30T09:00:00Z")           // scheduled, not sent yet
        for _ in 0..<5 { fake.add(chat: 1, from: 1, "", at: "2026-11-24T11:00:00Z") }         // unsent: no words left
        fake.add(chat: 1, from: 1, "first", at: "2026-11-24T09:00:00Z")
        fake.add(chat: 1, from: 1, "second", at: "2026-11-24T10:00:00Z")
        let store = try MessageStore(path: fake.path)
        #expect(try store.messages(chat: "+15550001", days: 30, limit: 2, now: Self.now).map(\.text) == ["first", "second"])
        #expect(try store.search(text: "birthday", days: 30, limit: 5, now: Self.now).isEmpty)
    }

    @Test func verificationCodesAndSignInLinksNeverLeaveTheReader() throws {
        for (text, sender) in [("Your verification code is 482913", "+15550001"), ("G-482913 is your Google verification code.", "+15550001"),
                               ("Use 4829 to log in", "sam@example.com"), ("Your OTP: 482 913. Do not share it.", "+15550001"),
                               ("Reset your password: https://bank.example/r?t=abc", "+15550001"),
                               ("Tap to sign in https://x.example/magic", "+15550001"),
                               ("Your verification code is ABC123", "+15550001"), ("Your Steam Guard code is K7P2D", "+15550001"),
                               ("Your code is 1234567890", "+15550001"), ("Your code is 482,913", "+15550001"), ("Your code is 12.34.56", "+15550001"),
                               ("123456", "+15550001"), ("G-482913", "+15550001"),
                               ("Sign in: example.com/m/abc123", "+15550001"), ("Click here to verify: bit.ly/3xYz", "+15550001")] {
            #expect(MessageStore.hidingCodes(text, sender: sender) == MessageStore.hiddenCode, "\(text)")
        }
        // Anything from an automated short number is hidden whatever it says.
        #expect(MessageStore.hidingCodes("Your parcel is out for delivery", sender: "72345") == MessageStore.hiddenAutomated)
        // Ordinary messages with numbers, or with those words but no code or link, come through.
        for text in ["See you at 1830 on Friday", "My door code talk can wait, call me", "It cost 12,500 in the end", "The pin fell out of my bike",
                     "Call me on 555 0100", "Flight BA 2490 lands 14/11/2026", "Can you confirm you're coming?", "https://example.com/recipe",
                     "ok", "Lunch at 1?", "See you in 10"] {
            #expect(MessageStore.hidingCodes(text, sender: "+15550001") == text, "\(text)")
        }

        let fake = FakeMessages()
        fake.add(chat: 1, from: 1, "Your verification code is 482913", at: "2026-11-24T09:00:00Z", packed: true)
        fake.add(chat: 1, from: 1, "Lunch at 1?", at: "2026-11-24T09:01:00Z")
        let store = try MessageStore(path: fake.path)
        #expect(try store.messages(chat: "+15550001", days: 30, limit: 10, now: Self.now).map(\.text) == [MessageStore.hiddenCode, "Lunch at 1?"])
        // A hidden message cannot be found by what it said.
        #expect(try store.search(text: "482913", days: 30, limit: 10, now: Self.now).isEmpty)
        #expect(try store.search(text: "verification", days: 30, limit: 10, now: Self.now).map(\.text) == [MessageStore.hiddenCode])
    }

    @Test func requestsAreAnsweredOrRefusedByCode() {
        let fake = filled()
        func ask(_ request: ReaderRequest) -> ReaderReply { ReaderServer.answer(request, databasePath: fake.path, now: Self.now) }
        #expect(ask(ReaderRequest(op: "status")) == ReaderReply(ok: true))
        #expect(ask(ReaderRequest(op: "chats")).chats?.count == 2)
        #expect(ask(ReaderRequest(op: "messages", chat: "chat99")).messages?.map(\.text) == ["Rent is due on Friday"])
        #expect(ask(ReaderRequest(op: "search", text: "rent")).messages?.count == 1)
        for bad in [ReaderRequest(op: "delete"), ReaderRequest(op: "messages"), ReaderRequest(op: "search", text: ""),
                    ReaderRequest(op: "sql", text: "SELECT * FROM message"), ReaderRequest(op: "messages", chat: String(repeating: "a", count: 300))] {
            #expect(ask(bad) == ReaderReply(ok: false, code: "bad_request"))
        }
        #expect(ReaderServer.answer(ReaderRequest(op: "chats"), databasePath: "/nonexistent/chat.db").ok == false)
    }
}

@Suite(.serialized) struct ReaderServerTests {
    /// Runs the server on a socket in a temporary folder and asks it one thing.
    func ask(_ request: ReaderRequest, trusting requirement: String, hardened: Bool = false, log: String? = nil) throws -> ReaderReply {
        let fake = MessageStoreTests().filled()
        // Short, because a socket's path has a small limit.
        let folder = "/tmp/omnis-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = folder + "/m.sock"
        let server = ReaderServer(socketPath: socket, databasePath: fake.path, callerRequirement: requirement, idleSeconds: 2,
                                  requireHardenedCaller: hardened, logPath: log)
        let thread = Thread { server.run() }
        thread.start()
        var descriptor: Int32 = -1
        for _ in 0..<100 where descriptor < 0 {
            descriptor = (try? LocalSocket.connect(to: socket)) ?? -1
            if descriptor < 0 { usleep(20_000) }
        }
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        LocalSocket.writeLine(descriptor, try JSONEncoder().encode(request))
        let line = try #require(LocalSocket.readLine(descriptor))
        return try JSONDecoder().decode(ReaderReply.self, from: line)
    }

    @Test func aCallerWithTheWrongSignatureIsToldNothing() throws {
        // This test program is not OMNIS, so a server that trusts only OMNIS refuses it.
        let omnis = #"identifier "local.omnis.app" and certificate leaf = H"bae46c520f5dc42f7bab5707c6a465495a09b4de""#
        #expect(try ask(ReaderRequest(op: "chats"), trusting: omnis) == ReaderReply(ok: false, code: "not_recognised"))
        #expect(try ask(ReaderRequest(op: "search", text: "rent"), trusting: "identifier \"somebody.else\"") == ReaderReply(ok: false, code: "not_recognised"))
        // A requirement that cannot even be read trusts nobody.
        #expect(try ask(ReaderRequest(op: "chats"), trusting: "this is not a requirement") == ReaderReply(ok: false, code: "not_recognised"))
    }

    @Test func onlyTheExactShapeOfRequirementIsBelieved() {
        let good = #"identifier "local.omnis.app" and certificate leaf = H"bae46c520f5dc42f7bab5707c6a465495a09b4de""#
        #expect(PeerCheck.isPinned(good, to: "local.omnis.app"))
        #expect(!PeerCheck.isPinned(good, to: "local.omnis.messages-reader"))
        for loose in [good + " or anchor apple", "anchor apple", #"identifier "local.omnis.app""#,
                      #"identifier "local.omnis.app" and certificate leaf = H"BAE4""#,
                      #"identifier "local.omnis.app" and certificate leaf = H"bae46c520f5dc42f7bab5707c6a465495a09b4de" or anchor apple"#, ""] {
            #expect(!PeerCheck.isPinned(loose, to: "local.omnis.app"), "\(loose)")
        }
    }

    @Test func aFolderThatIsALinkOrOpenToOthersIsNotUsed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-folder-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link"), open = base.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ReaderServer.folderIsSafe(real.path))
        #expect(!ReaderServer.folderIsSafe(link.path) && !ReaderServer.folderIsSafe(open.path) && !ReaderServer.folderIsSafe(base.path + "/missing"))
    }

    @Test func aCallerThatWasNotBuiltHardenedCanBeRefusedAndEveryRequestIsLogged() throws {
        var code: SecCode?
        SecCodeCopySelf([], &code)
        var staticCode: SecStaticCode?
        SecCodeCopyStaticCode(try #require(code), [], &staticCode)
        var information: CFDictionary?
        SecCodeCopySigningInformation(try #require(staticCode), [], &information)
        let identifier = try #require((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-reader-\(UUID().uuidString).log").path
        // This test program meets the name, but if it was not built hardened a strict server refuses it.
        let strict = try ask(ReaderRequest(op: "search", text: "rent"), trusting: "identifier \"\(identifier)\"", hardened: true, log: log)
        let plain = try ask(ReaderRequest(op: "search", text: "rent"), trusting: "identifier \"\(identifier)\"", log: log)
        #expect(plain.ok)
        let lines = try String(contentsOfFile: log, encoding: .utf8)
        #expect(lines.contains(#""op":"search""#) && lines.contains(#""messages":1"#))
        if !strict.ok { #expect(lines.contains("refused_caller")) }
        // What was looked for, and what was found, are not written down.
        #expect(!lines.lowercased().contains("rent") && !lines.contains("chat99") && !lines.contains("+1555"))
    }

    @Test func aCallerThatMeetsTheRequirementIsAnswered() throws {
        // What this test program is signed as, asked of the system rather than assumed.
        var code: SecCode?
        SecCodeCopySelf([], &code)
        var staticCode: SecStaticCode?
        SecCodeCopyStaticCode(try #require(code), [], &staticCode)
        var information: CFDictionary?
        SecCodeCopySigningInformation(try #require(staticCode), [], &information)
        let identifier = try #require((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
        let reply = try ask(ReaderRequest(op: "messages", chat: "chat99"), trusting: "identifier \"\(identifier)\"")
        #expect(reply.ok && reply.messages?.map(\.text) == ["Rent is due on Friday"])
    }
}
