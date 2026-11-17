import Foundation

/// The message protocol shared with `backend/omnis_backend/protocol.py`.
/// One JSON object per line. Keep the two files in step.
public enum BackendProtocol {
    public static let version = 2
}

public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int)
    case ask(id: String, text: String, route: String = "auto", web: Bool = true)
    case cancel(id: String)
    /// The app's reply to a `toolRequest`: what the search found, or why it failed.
    case toolResult(id: String, callID: String, ok: Bool, results: [SearchResult], error: String)
}

/// What produced an answer and what it cost. All fields are optional on the
/// wire; the mock backend sends none of them.
public struct AnswerDetails: Equatable, Sendable {
    /// "local", "cloud-mock" or "mock".
    public var route: String?
    /// Why this model was chosen, in plain words.
    public var reason: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var loadMilliseconds: Int?
    public var totalMilliseconds: Int?
    public var costUSD: Double?
    /// How many web searches were made for this answer.
    public var searches: Int?

    public init(route: String? = nil, reason: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                loadMilliseconds: Int? = nil, totalMilliseconds: Int? = nil, costUSD: Double? = nil,
                searches: Int? = nil) {
        self.route = route
        self.reason = reason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.loadMilliseconds = loadMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.costUSD = costUSD
        self.searches = searches
    }
}

public enum ServiceMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, service: String, version: String)
    case answerChunk(id: String, text: String)
    case answerDone(id: String, model: String?, cancelled: Bool, details: AnswerDetails)
    /// The model wants the app to do something. Only "web_search" exists.
    case toolRequest(id: String, callID: String, tool: String, query: String)
    case error(id: String?, code: String, message: String)
    case bye(reason: String)
}

public enum ProtocolCodecError: Error, Equatable {
    case notJSONObject
    case unknownType(String)
    case missingField(String)
}

public enum ProtocolCodec {
    /// Encodes one message as a single line, without the trailing newline.
    public static func encode(_ message: ClientMessage) throws -> Data {
        let object: [String: Any]
        switch message {
        case .hello(let version):
            object = ["type": "hello", "protocol": version]
        case .ask(let id, let text, let route, let web):
            object = ["type": "ask", "id": id, "text": text, "route": route, "web": web]
        case .toolResult(let id, let callID, let ok, let results, let error):
            object = [
                "type": "tool_result", "id": id, "call_id": callID, "ok": ok, "error": error,
                "results": results.map { ["title": $0.title, "url": $0.url.absoluteString, "snippet": $0.snippet] },
            ]
        case .cancel(let id):
            object = ["type": "cancel", "id": id]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func decode(_ line: Data) throws -> ServiceMessage {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw ProtocolCodecError.notJSONObject
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw ProtocolCodecError.missingField(key) }
            return value
        }
        func integer(_ key: String) throws -> Int {
            // JSON true/false also bridge to NSNumber; refuse them.
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ProtocolCodecError.missingField(key)
            }
            return number.intValue
        }

        let type = try string("type")
        switch type {
        case "hello":
            return .hello(protocolVersion: try integer("protocol"), service: try string("service"), version: try string("version"))
        case "answer_chunk":
            return .answerChunk(id: try string("id"), text: try string("text"))
        case "answer_done":
            func optionalInt(_ key: String) -> Int? {
                guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                return number.intValue
            }
            func optionalText(_ key: String) -> String? {
                (object[key] as? String).map { String($0.prefix(200)) }
            }
            let cost = (object["cost_usd"] as? NSNumber).flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.doubleValue : nil }
            return .answerDone(
                id: try string("id"),
                model: object["model"] as? String,
                cancelled: (object["cancelled"] as? Bool) ?? false,
                details: AnswerDetails(
                    route: optionalText("route"),
                    reason: optionalText("reason"),
                    inputTokens: optionalInt("input_tokens"),
                    outputTokens: optionalInt("output_tokens"),
                    loadMilliseconds: optionalInt("load_ms"),
                    totalMilliseconds: optionalInt("total_ms"),
                    costUSD: cost,
                    searches: optionalInt("searches")
                )
            )
        case "tool_request":
            return .toolRequest(id: try string("id"), callID: try string("call_id"),
                                tool: try string("tool"), query: String(try string("query").prefix(400)))
        case "error":
            return .error(id: object["id"] as? String, code: try string("code"), message: try string("message"))
        case "bye":
            return .bye(reason: try string("reason"))
        default:
            throw ProtocolCodecError.unknownType(type)
        }
    }
}
