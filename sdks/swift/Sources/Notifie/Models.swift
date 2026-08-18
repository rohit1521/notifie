import Foundation

/// Flat scalar property values the server accepts.
/// Nested objects are rejected server-side, so nesting is not representable here.
public enum NotifieProperty: Sendable, Equatable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case null
}

extension NotifieProperty: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }
}

extension NotifieProperty: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.typeMismatch(
                NotifieProperty.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported scalar type")
            )
        }
    }
}

public typealias Properties = [String: NotifieProperty]

/// An event ready to be sent to the ingest endpoint.
struct NotifieEvent: Codable, Sendable {
    let messageId: String
    let event: String
    let timestamp: Date
    let userId: String?
    let anonymousId: String?
    let properties: Properties

    enum CodingKeys: String, CodingKey {
        case messageId, event, timestamp, userId, anonymousId, properties
    }
}

struct TrackBatchBody: Encodable {
    let events: [NotifieEvent]
    let sentAt: Date
}

/// Decodable as well as Encodable because an identify that could not be
/// delivered is persisted and replayed; the server keys user properties by
/// external id, so dropping one silently strands a profile.
struct IdentifyBody: Codable, Equatable {
    let userId: String?
    let anonymousId: String?
    let properties: Properties
    let timestamp: Date
}

/// Wire body for the push-token registration endpoint.
struct PushTokenBody: Codable, Equatable {
    let userId: String?
    let anonymousId: String?
    let token: String
    /// "ios" or "android"
    let platform: String
    /// "apns" or "fcm"
    let provider: String
}

struct PushTokenRevocationBody: Encodable {
    let token: String
}
