import Foundation
import Testing
@testable import OmnisCore

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ iso: String) { current = ISO8601DateFormatter().date(from: iso)! }
    var now: Date { lock.withLock { current } }
    func set(_ iso: String) { lock.withLock { current = ISO8601DateFormatter().date(from: iso)! } }
}

@Suite struct UsageLedgerTests {
    func ledger(_ scratch: Scratch, _ clock: Clock) -> UsageLedger {
        UsageLedger(url: scratch.url.appendingPathComponent("OMNIS/claude-usage.csv"), now: { clock.now })
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func recordsNumbersOnlyInAPrivateSpreadsheetFile() throws {
        let scratch = try Scratch()
        let clock = Clock("2026-11-17T12:00:00Z")
        let ledger = ledger(scratch, clock)
        ledger.record(model: "claude-haiku-5-5", inputTokens: 2000, outputTokens: 500, costUSD: 0.00045)
        ledger.record(model: "claude-sonnet-5-5", inputTokens: 1000, outputTokens: 100, costUSD: 0.003)

        let file = scratch.url.appendingPathComponent("OMNIS/claude-usage.csv")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
            "time,model,input_tokens,output_tokens,cost_usd",
            "2026-11-17T12:00:00Z,claude-haiku-5-5,2000,500,0.000450",
            "2026-11-17T12:00:00Z,claude-sonnet-5-5,1000,100,0.003000",
        ])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(ledger.entries().map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5"])
    }

    @Test func aModelNameCannotAddColumnsOrFormulas() throws {
        let scratch = try Scratch()
        let ledger = ledger(scratch, Clock("2026-11-17T12:00:00Z"))
        ledger.record(model: "=HYPERLINK(\"http://x\"),9,9,999\nevil", inputTokens: -5, outputTokens: 3, costUSD: -1)
        let entries = ledger.entries()
        #expect(entries.count == 1)
        #expect(entries[0].model == "HYPERLINKhttpx99999evil")
        #expect(!entries[0].model.contains(where: { "=,(\"\n".contains($0) }))
        #expect(entries[0].inputTokens == 0)
        #expect(entries[0].costUSD == 0)
    }

    @Test func theMonthTotalCountsOnlyThatMonth() throws {
        let scratch = try Scratch()
        let clock = Clock("2026-10-31T23:00:00Z")
        let ledger = ledger(scratch, clock)
        ledger.record(model: "claude-haiku-5-5", inputTokens: 1, outputTokens: 1, costUSD: 5.0)
        clock.set("2026-11-01T01:00:00Z")
        ledger.record(model: "claude-haiku-5-5", inputTokens: 1, outputTokens: 1, costUSD: 2.0)
        clock.set("2026-11-17T12:00:00Z")
        ledger.record(model: "claude-haiku-5-5", inputTokens: 1, outputTokens: 1, costUSD: 1.5)
        #expect(abs(ledger.monthTotal(calendar: utc) - 3.5) < 1e-9)
        #expect(abs(ledger.monthTotal(containing: ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!, calendar: utc) - 5.0) < 1e-9)
        clock.set("2026-12-01T12:00:00Z")
        #expect(ledger.monthTotal(calendar: utc) == 0)   // a new month starts from nothing
    }

    @Test func theMonthlyLimitIsAHardStopAndWarningsComeFirst() throws {
        let scratch = try Scratch()
        let clock = Clock("2026-11-17T12:00:00Z")
        let ledger = ledger(scratch, clock)
        let limits = CloudLimits(perRequestUSD: 1.0, perMonthUSD: 20.0)

        #expect(ledger.permission(limits: limits) == CloudPermission(allowed: true, maxUSD: 1.0))
        #expect(ledger.warning(limits: limits) == nil)

        ledger.record(model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1, costUSD: 10.4)
        #expect(ledger.warning(limits: limits) == "52% of this month's Claude budget used")
        #expect(ledger.permission(limits: limits).allowed)

        ledger.record(model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1, costUSD: 9.2)
        // 40 cents left: one request may not take the month over its limit.
        let nearly = ledger.permission(limits: limits)
        #expect(nearly.allowed)
        #expect(abs(nearly.maxUSD - 0.4) < 1e-9)
        #expect(ledger.warning(limits: limits) == "98% of this month's Claude budget used")

        ledger.record(model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1, costUSD: 0.4)
        #expect(ledger.permission(limits: limits)
            == CloudPermission(allowed: false, maxUSD: 0, reason: "this month's Claude budget is used up"))
    }

    @Test func aDamagedFileIsReadAsFarAsItMakesSense() throws {
        let scratch = try Scratch()
        let file = try scratch.file("OMNIS/claude-usage.csv", contents: """
        time,model,input_tokens,output_tokens,cost_usd
        2026-11-17T12:00:00Z,claude-haiku-5-5,10,5,0.25
        not a line
        2026-11-17T12:00:00Z,claude-haiku-5-5,ten,5,0.25
        2026-11-17T12:00:00Z,claude-haiku-5-5,10,5,-3
        2026-11-17T12:00:00Z,claude-haiku-5-5,10,5,nan
        2026-11-17T13:00:00Z,claude-haiku-5-5,10,5,0.50

        """)
        let ledger = UsageLedger(url: file, now: { ISO8601DateFormatter().date(from: "2026-11-17T14:00:00Z")! })
        #expect(ledger.entries().count == 2)
        #expect(abs(ledger.monthTotal(calendar: utc) - 0.75) < 1e-9)
    }
}

@Suite struct KeychainStoreTests {
    @Test func savesReplacesAndRemovesAValue() {
        let store = KeychainStore(service: "local.omnis.tests", account: "key-\(UUID().uuidString)")
        defer { store.delete() }
        #expect(store.read() == nil)
        guard store.save("  first-value \n") else {
            // No usable Keychain here (for example a locked or headless session).
            return
        }
        #expect(store.read() == "first-value")
        #expect(store.save("second-value"))
        #expect(store.read() == "second-value")
        #expect(!store.save("   "))             // an empty value is refused, the old one kept
        #expect(store.read() == "second-value")
        #expect(store.delete())
        #expect(store.read() == nil)
        #expect(store.delete())                 // removing nothing is not an error
    }
}

@Suite struct ConversationLocalRuleTests {
    @Test func keepingOneTurnLocalKeepsTheChatLocalUntilANewChat() {
        var chat = Conversation()
        #expect(!chat.staysLocal)
        let id = chat.begin(question: "private thing")
        chat.keepLocal()
        chat.update(id) { $0.text = "ok"; $0.state = .done }
        _ = chat.begin(question: "a public follow-up")
        #expect(chat.staysLocal)
        chat.clear()
        #expect(!chat.staysLocal)
    }
}
