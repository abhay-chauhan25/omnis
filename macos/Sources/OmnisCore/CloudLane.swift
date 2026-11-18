import Foundation
import Security

/// The app's say on whether Claude may be used for one question. The app
/// owns the spending limits; the backend is told the result and obeys it.
public struct CloudPermission: Equatable, Sendable {
    public var allowed: Bool
    /// The most one request may cost, in US dollars.
    public var maxUSD: Double
    /// Why Claude is not allowed, in a few words, when it is not.
    public var reason: String

    public init(allowed: Bool = true, maxUSD: Double = 1.0, reason: String = "") {
        self.allowed = allowed
        self.maxUSD = maxUSD
        self.reason = reason
    }
}

/// Spending limits for Claude (ADR-0006).
public struct CloudLimits: Equatable, Sendable {
    public var perRequestUSD: Double
    public var perMonthUSD: Double
    public var warningFractions: [Double]

    public init(perRequestUSD: Double = 1.0, perMonthUSD: Double = 20.0, warningFractions: [Double] = [0.5, 0.8]) {
        self.perRequestUSD = perRequestUSD
        self.perMonthUSD = perMonthUSD
        self.warningFractions = warningFractions
    }
}

/// A record of what Claude has cost, one line per answer, as a CSV file that
/// can be opened in a spreadsheet. It holds numbers only: no questions, no answers.
public final class UsageLedger: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let time: Date
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let costUSD: Double
    }

    public static let header = "time,model,input_tokens,output_tokens,cost_usd"

    private let url: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func record(model: String, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data((Self.header + "\n").utf8),
                                   attributes: [.posixPermissions: 0o600])
        }
        // Only letters, digits, dots and dashes are kept, so a model name can
        // never add a column or a formula to the file.
        let safeModel = String(model.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }.prefix(60))
        let stamp = ISO8601DateFormatter().string(from: now())
        let line = "\(stamp),\(safeModel),\(max(0, inputTokens)),\(max(0, outputTokens)),\(String(format: "%.6f", max(0, costUSD)))\n"
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    public func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let time = formatter.date(from: fields[0]),
                  let input = Int(fields[2]), let output = Int(fields[3]), let cost = Double(fields[4]),
                  cost.isFinite, cost >= 0 else { return nil }
            return Entry(time: time, model: fields[1], inputTokens: input, outputTokens: output, costUSD: cost)
        }
    }

    /// What has been spent in the calendar month containing `date`.
    public func monthTotal(containing date: Date? = nil, calendar: Calendar = .current) -> Double {
        let reference = date ?? now()
        return entries()
            .filter { calendar.isDate($0.time, equalTo: reference, toGranularity: .month) }
            .reduce(0) { $0 + $1.costUSD }
    }

    /// Whether Claude may be used now, given what this month has cost so far.
    public func permission(limits: CloudLimits = CloudLimits()) -> CloudPermission {
        let spent = monthTotal()
        if spent >= limits.perMonthUSD {
            return CloudPermission(allowed: false, maxUSD: 0, reason: "this month's Claude budget is used up")
        }
        // Never let one request take the month over its limit.
        return CloudPermission(allowed: true, maxUSD: min(limits.perRequestUSD, limits.perMonthUSD - spent))
    }

    /// A short note once a warning level has been passed, such as "52% of this month's budget used".
    public func warning(limits: CloudLimits = CloudLimits()) -> String? {
        guard limits.perMonthUSD > 0 else { return nil }
        let fraction = monthTotal() / limits.perMonthUSD
        guard let lowest = limits.warningFractions.min(), fraction >= lowest else { return nil }
        return "\(Int((fraction * 100).rounded()))% of this month's Claude budget used"
    }
}

/// The Claude API key, kept in the macOS Keychain. It is never written to a
/// file, a log, or the audit record.
public struct KeychainStore: Sendable {
    public let service: String
    public let account: String

    public static let claudeKey = KeychainStore(service: "local.omnis.app", account: "anthropic-api-key")

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Saves the value, replacing any earlier one. Returns false if the Keychain refused.
    @discardableResult
    public func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
