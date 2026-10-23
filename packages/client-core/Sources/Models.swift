import Foundation
import CryptoKit

public enum RecordKind: String, Codable, CaseIterable, Identifiable {
    case comment, question, answer, evaluation, relation, decision
    public var id: String { rawValue }
}

public enum RecordOperation: String, Codable { case record, withdrawal }

public struct SourceSnapshot: Codable, Equatable {
    public let url: String
    public let title: String
    public let quote: String
    public let capturedAt: String
    public let quoteDigest: String

    public init(url: String, title: String, quote: String, capturedAt: Date = Date()) {
        self.url = url
        self.title = title
        self.quote = quote
        self.capturedAt = ProtocolV0.timestamp(capturedAt)
        self.quoteDigest = ProtocolV0.digest(Data(quote.utf8))
    }
}

public struct RecordDraft: Equatable {
    public let source: SourceSnapshot
    public let kind: RecordKind
    public let text: String
    public let relationTargetID: String?
    public let relationKind: String?
    public let evaluationCriterion: String?
    public let evaluationValue: String?
    public let disposition: String?
    public let branchID: String

    public init(source: SourceSnapshot, kind: RecordKind, text: String,
                relationTargetID: String? = nil, relationKind: String? = nil,
                evaluationCriterion: String? = nil, evaluationValue: String? = nil,
                disposition: String? = nil, branchID: String = "main") {
        self.source = source; self.kind = kind; self.text = text
        self.relationTargetID = relationTargetID; self.relationKind = relationKind
        self.evaluationCriterion = evaluationCriterion; self.evaluationValue = evaluationValue
        self.disposition = disposition; self.branchID = branchID
    }
}

public struct RecordPayload: Codable, Equatable {
    public let protocolVersion: String
    public let canonicalization: String
    public let actorID: String
    public let keyID: String
    public let publicKey: String
    public let operation: RecordOperation
    public let kind: RecordKind
    public let source: SourceSnapshot
    public let text: String
    public let relationTargetID: String
    public let relationKind: String
    public let evaluationCriterion: String
    public let evaluationValue: String
    public let disposition: String
    public let branchID: String
    public let createdAt: String
    public let nonce: String
    public let withdrawnRecordID: String
}

public struct SignedRecord: Codable, Equatable, Identifiable {
    public let id: String
    public let payload: RecordPayload
    public let signature: String
    public var publicKey: String { payload.publicKey }
    public var actorID: String { payload.actorID }
    public var source: SourceSnapshot { payload.source }
    public var kind: RecordKind { payload.kind }
    public var text: String { payload.text }
    public var createdAt: String { payload.createdAt }
    public var operation: RecordOperation { payload.operation }
    public var withdrawnRecordID: String? {
        payload.withdrawnRecordID.isEmpty ? nil : payload.withdrawnRecordID
    }
    public var relationTargetID: String? {
        payload.relationTargetID.isEmpty ? nil : payload.relationTargetID
    }
    public func canonicalPayloadData() -> Data { ProtocolV0.canonicalData(payload) }
}

public enum WithdrawalStatus: String { case notWithdrawal, pendingOriginal, authorized, unauthorized }

public struct ImportResult {
    public let inserted: Int
    public let duplicates: Int
    public let pendingWithdrawals: Int
}

public enum LedgerError: Error, LocalizedError {
    case invalidRecord(String), unsupportedSchema(String), database(String)
    case unknownRecord, notOwner, keychain(String), archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let reason): return "기록 검증 실패: \(reason)"
        case .unsupportedSchema(let version): return "지원하지 않는 기록 형식: \(version)"
        case .database(let message): return "로컬 저장소 오류: \(message)"
        case .unknownRecord: return "철회할 원본 기록을 찾을 수 없습니다."
        case .notOwner: return "현재 키로 작성한 기록만 철회할 수 있습니다."
        case .keychain(let message): return "서명 키를 사용할 수 없습니다. 키를 자동 초기화하지 않았습니다. \(message)"
        case .archiveTooLarge: return "가져오기 파일이 알파의 크기 또는 기록 수 한도를 초과했습니다."
        }
    }
}

// An experimental, fixed-schema encoding. This is NOT a general JCS implementation.
// Every signed leaf is a string. Fields are flattened and sorted by ASCII field name.
// Strings use JSON escaping, preserving Unicode scalar sequences without normalization.
enum ProtocolV0 {
    static let version = "human-browser-local-alpha/0"
    static let canonicalization = "fixed-string-json/0"
    static let archiveFormat = "human-browser-local-archive/0"
    static let maximumArchiveBytes = 8 * 1024 * 1024
    static let maximumRecords = 10_000
    static let maximumPayloadBytes = 128 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    static func validTimestamp(_ text: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else { return false }
        return timestamp(date) == text
    }
    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0...0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    static func canonicalData(_ p: RecordPayload) -> Data {
        let fields: [String: String] = [
            "actorID": p.actorID, "branchID": p.branchID,
            "canonicalization": p.canonicalization, "createdAt": p.createdAt,
            "disposition": p.disposition, "evaluationCriterion": p.evaluationCriterion,
            "evaluationValue": p.evaluationValue, "keyID": p.keyID,
            "kind": p.kind.rawValue, "nonce": p.nonce, "operation": p.operation.rawValue,
            "protocolVersion": p.protocolVersion, "publicKey": p.publicKey,
            "relationKind": p.relationKind, "relationTargetID": p.relationTargetID,
            "source.capturedAt": p.source.capturedAt, "source.quote": p.source.quote,
            "source.quoteDigest": p.source.quoteDigest, "source.title": p.source.title,
            "source.url": p.source.url, "text": p.text, "withdrawnRecordID": p.withdrawnRecordID
        ]
        return Data(("{" + fields.keys.sorted().map { quoted($0) + ":" + quoted(fields[$0]!) }.joined(separator: ",") + "}").utf8)
    }
    static func isEventID(_ id: String) -> Bool {
        id.hasPrefix("event:") && isHex(String(id.dropFirst(6)), count: 64)
    }
    static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
