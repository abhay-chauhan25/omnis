import Foundation

/// The message protocol shared with `backend/omnis_backend/protocol.py`.
/// One JSON object per line. Keep the two files in step.
public enum BackendProtocol {
    public static let version = 1
}

public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int)
    case ask(id: String, text: String)
    case cancel(id: String)
}

public enum ServiceMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, service: String, version: String)
    case answerChunk(id: String, text: String)
    case answerDone(id: String, model: String?, cancelled: Bool)
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
        case .ask(let id, let text):
            object = ["type": "ask", "id": id, "text": text]
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
            return .answerDone(
                id: try string("id"),
                model: object["model"] as? String,
                cancelled: (object["cancelled"] as? Bool) ?? false
            )
        case "error":
            return .error(id: object["id"] as? String, code: try string("code"), message: try string("message"))
        case "bye":
            return .bye(reason: try string("reason"))
        default:
            throw ProtocolCodecError.unknownType(type)
        }
    }
}
