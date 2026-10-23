import Foundation
import CryptoKit
import CSQLite

private struct LedgerArchive: Codable {
    let format: String
    let records: [SignedRecord]
}

public final class LedgerStore {
    private var database: OpaquePointer?
    private let signer: any RecordSigner
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public var actorID: String { "actor:" + ProtocolV0.digest(signer.publicKeyData) }

    public init(directory: URL, signer: (any RecordSigner)? = nil) throws {
        let path = directory.appendingPathComponent("ledger.sqlite3").path
        self.signer = try signer ?? KeychainSigner(allowCreation: !FileManager.default.fileExists(atPath: path))
        guard self.signer.publicKeyData.count == 32 else { throw LedgerError.invalidRecord("Ed25519 공개키 길이") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "데이터베이스 열기 실패"
            if let database { sqlite3_close(database) }
            database = nil
            throw LedgerError.database(message)
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=3000")
            try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY NOT NULL, source_url TEXT NOT NULL, created_at TEXT NOT NULL, record_json BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS records_source ON records(source_url)")
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    /// Call only after the app has shown this exact draft and received an explicit local-save action.
    /// This method does not prove a human was present; no record is sent to any network service.
    @discardableResult public func commitDraft(_ draft: RecordDraft) throws -> SignedRecord {
        try locked {
            let record = try sign(draft: draft, operation: .record, target: "")
            try Self.verify(record)
            try transaction { _ = try insert(record) }
            return record
        }
    }

    /// Withdraws exactly one original record. Other records, revisions, and other actors remain intact.
    @discardableResult public func withdraw(recordID: String) throws -> SignedRecord {
        try locked {
            let records = try readAll()
            guard let original = records.first(where: { $0.id == recordID && $0.operation == .record }) else {
                throw LedgerError.unknownRecord
            }
            guard original.actorID == actorID else { throw LedgerError.notOwner }
            if let prior = records.first(where: { $0.operation == .withdrawal && $0.withdrawnRecordID == recordID && $0.actorID == actorID }) {
                return prior
            }
            let draft = RecordDraft(source: original.source, kind: original.kind, text: "", branchID: original.payload.branchID)
            let record = try sign(draft: draft, operation: .withdrawal, target: recordID)
            try Self.verify(record)
            try transaction { _ = try insert(record) }
            return record
        }
    }

    public func allRecords(sourceURL: String? = nil) throws -> [SignedRecord] {
        try locked { try readAll(sourceURL: sourceURL) }
    }
    public func activeRecords(sourceURL: String? = nil) throws -> [SignedRecord] {
        try locked {
            let all = try readAll()
            let withdrawn = authorizedWithdrawalTargets(all)
            return all.filter { $0.operation == .record && !withdrawn.contains($0.id) && (sourceURL == nil || $0.source.url == sourceURL) }
        }
    }
    public func isWithdrawn(_ recordID: String) throws -> Bool {
        try locked { authorizedWithdrawalTargets(try readAll()).contains(recordID) }
    }
    public func withdrawalStatus(_ record: SignedRecord) throws -> WithdrawalStatus {
        try locked {
            guard record.operation == .withdrawal, let target = record.withdrawnRecordID else { return .notWithdrawal }
            guard let original = try readAll().first(where: { $0.id == target && $0.operation == .record }) else { return .pendingOriginal }
            return original.actorID == record.actorID ? .authorized : .unauthorized
        }
    }

    public func exportData() throws -> Data {
        try locked {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(LedgerArchive(format: ProtocolV0.archiveFormat, records: try readAll()))
        }
    }

    /// Verifies the entire archive before one atomic SQLite transaction. A duplicate ID is a no-op.
    @discardableResult public func importData(_ data: Data) throws -> ImportResult {
        try locked {
            guard data.count <= ProtocolV0.maximumArchiveBytes else { throw LedgerError.archiveTooLarge }
            try Self.validateArchiveShape(data)
            let archive: LedgerArchive
            do { archive = try JSONDecoder().decode(LedgerArchive.self, from: data) }
            catch { throw LedgerError.invalidRecord("가져오기 JSON 형식: \(error.localizedDescription)") }
            guard archive.format == ProtocolV0.archiveFormat else { throw LedgerError.unsupportedSchema(archive.format) }
            guard archive.records.count <= ProtocolV0.maximumRecords else { throw LedgerError.archiveTooLarge }
            for record in archive.records { try Self.verify(record) }
            var inserted = 0
            try transaction {
                for record in archive.records { if try insert(record) { inserted += 1 } }
            }
            let all = try readAll()
            let originals = Set(all.filter { $0.operation == .record }.map(\.id))
            let pending = all.filter { $0.operation == .withdrawal && !originals.contains($0.payload.withdrawnRecordID) }.count
            return ImportResult(inserted: inserted, duplicates: archive.records.count - inserted, pendingWithdrawals: pending)
        }
    }

    public static func verify(_ record: SignedRecord) throws {
        let p = record.payload
        guard p.protocolVersion == ProtocolV0.version, p.canonicalization == ProtocolV0.canonicalization else {
            throw LedgerError.unsupportedSchema(p.protocolVersion + " / " + p.canonicalization)
        }
        guard let keyData = Data(base64Encoded: p.publicKey), keyData.count == 32,
              keyData.base64EncodedString() == p.publicKey,
              let signature = Data(base64Encoded: record.signature), signature.count == 64,
              signature.base64EncodedString() == record.signature else { throw LedgerError.invalidRecord("키 또는 서명 인코딩") }
        let fingerprint = ProtocolV0.digest(keyData)
        guard p.actorID == "actor:" + fingerprint, p.keyID == "key:" + fingerprint else {
            throw LedgerError.invalidRecord("주체와 공개키 결합 불일치")
        }
        guard ProtocolV0.validTimestamp(p.createdAt), ProtocolV0.validTimestamp(p.source.capturedAt),
              ProtocolV0.isHex(p.nonce, count: 32) else { throw LedgerError.invalidRecord("시각 또는 nonce 형식") }
        guard let url = URLComponents(string: p.source.url), !p.source.url.contains("\u{0}") else { throw LedgerError.invalidRecord("출처 URL 형식") }
        let scheme = url.scheme?.lowercased() ?? ""
        let webSource = ["http", "https"].contains(scheme) && !(url.host ?? "").isEmpty
        let localSource = scheme == "file" && url.path.hasPrefix("/") && ["", "localhost"].contains(url.host ?? "")
        guard webSource || localSource else { throw LedgerError.invalidRecord("출처 URL 형식") }
        guard p.source.quoteDigest == ProtocolV0.digest(Data(p.source.quote.utf8)) else {
            throw LedgerError.invalidRecord("인용문 해시 불일치")
        }
        guard !p.branchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              p.branchID.utf8.count <= 256 else { throw LedgerError.invalidRecord("발행 갈래 형식") }
        if p.operation == .withdrawal {
            guard ProtocolV0.isEventID(p.withdrawnRecordID), p.withdrawnRecordID != record.id,
                  p.text.isEmpty, p.relationTargetID.isEmpty, p.relationKind.isEmpty,
                  p.evaluationCriterion.isEmpty, p.evaluationValue.isEmpty, p.disposition.isEmpty else {
                throw LedgerError.invalidRecord("철회 대상 또는 본문 형식")
            }
        } else {
            guard p.withdrawnRecordID.isEmpty else { throw LedgerError.invalidRecord("일반 기록에 철회 대상 존재") }
            if [.comment, .question, .answer, .relation].contains(p.kind) {
                guard !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalidRecord("본문이 필요합니다") }
            }
            if p.kind == .evaluation {
                guard !p.evaluationCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !p.evaluationValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LedgerError.invalidRecord("평가 기준과 값이 필요합니다")
                }
            } else if !p.evaluationCriterion.isEmpty || !p.evaluationValue.isEmpty { throw LedgerError.invalidRecord("평가 외 기록의 평가 필드") }
            if p.kind == .relation {
                guard ProtocolV0.isEventID(p.relationTargetID), !p.relationKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LedgerError.invalidRecord("관계 종류와 정확한 대상 ID가 필요합니다")
                }
            } else {
                guard p.relationKind.isEmpty else { throw LedgerError.invalidRecord("관계 외 기록의 관계 종류") }
                if [.answer, .evaluation].contains(p.kind) {
                    guard p.relationTargetID.isEmpty || ProtocolV0.isEventID(p.relationTargetID) else { throw LedgerError.invalidRecord("답변 또는 평가 대상 ID 형식") }
                } else if !p.relationTargetID.isEmpty { throw LedgerError.invalidRecord("이 종류의 기록에는 대상 ID를 지정할 수 없습니다") }
            }
            if p.kind != .decision && !p.disposition.isEmpty { throw LedgerError.invalidRecord("정리 외 기록의 종료 상태") }
        }
        let canonical = ProtocolV0.canonicalData(p)
        guard canonical.count <= ProtocolV0.maximumPayloadBytes else { throw LedgerError.invalidRecord("본문 크기 제한") }
        guard record.id == "event:" + ProtocolV0.digest(canonical) else { throw LedgerError.invalidRecord("기록 ID 불일치") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signature, for: canonical) else { throw LedgerError.invalidRecord("서명 불일치") }
    }

    private func sign(draft: RecordDraft, operation: RecordOperation, target: String) throws -> SignedRecord {
        let fingerprint = ProtocolV0.digest(signer.publicKeyData)
        let payload = RecordPayload(protocolVersion: ProtocolV0.version, canonicalization: ProtocolV0.canonicalization,
            actorID: "actor:" + fingerprint, keyID: "key:" + fingerprint, publicKey: signer.publicKeyData.base64EncodedString(),
            operation: operation, kind: draft.kind, source: draft.source, text: draft.text,
            relationTargetID: draft.relationTargetID ?? "", relationKind: draft.relationKind ?? "",
            evaluationCriterion: draft.evaluationCriterion ?? "", evaluationValue: draft.evaluationValue ?? "",
            disposition: draft.disposition ?? "", branchID: draft.branchID,
            createdAt: ProtocolV0.timestamp(Date()), nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            withdrawnRecordID: target)
        let canonical = ProtocolV0.canonicalData(payload)
        return SignedRecord(id: "event:" + ProtocolV0.digest(canonical), payload: payload, signature: try signer.sign(canonical).base64EncodedString())
    }
    private func authorizedWithdrawalTargets(_ records: [SignedRecord]) -> Set<String> {
        let originals = Dictionary(uniqueKeysWithValues: records.filter { $0.operation == .record }.map { ($0.id, $0) })
        return Set(records.compactMap { withdrawal in
            guard withdrawal.operation == .withdrawal, let target = withdrawal.withdrawnRecordID,
                  let original = originals[target], original.actorID == withdrawal.actorID else { return nil }
            return target
        })
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }
    private func databaseError() -> LedgerError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "저장소 닫힘")
    }
    private func insert(_ record: SignedRecord) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO records(id,source_url,created_at,record_json) VALUES(?,?,?,?) ON CONFLICT(id) DO NOTHING", -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        let data = try JSONEncoder().encode(record)
        guard sqlite3_bind_text(statement, 1, record.id, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, record.source.url, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, record.createdAt, -1, transient) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else { throw databaseError() }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return sqlite3_changes(database) == 1
    }
    private func readAll(sourceURL: String? = nil) throws -> [SignedRecord] {
        var statement: OpaquePointer?
        let sql = "SELECT record_json FROM records" + (sourceURL == nil ? "" : " WHERE source_url = ?") + " ORDER BY created_at, id"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        if let sourceURL, sqlite3_bind_text(statement, 1, sourceURL, -1, transient) != SQLITE_OK { throw databaseError() }
        var result: [SignedRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw databaseError() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let record = try JSONDecoder().decode(SignedRecord.self, from: data)
            try Self.verify(record)
            result.append(record)
        }
        return result
    }
    private static func validateArchiveShape(_ data: Data) throws {
        try validateJSONKeysAndDepth(data)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw LedgerError.invalidRecord("JSON 해석 실패") }
        guard let archive = root as? [String: Any], Set(archive.keys) == ["format", "records"],
              archive["format"] is String, let records = archive["records"] as? [[String: Any]] else {
            throw LedgerError.invalidRecord("가져오기 봉투 필드")
        }
        let payloadKeys: Set<String> = ["protocolVersion", "canonicalization", "actorID", "keyID", "publicKey", "operation", "kind", "source", "text", "relationTargetID", "relationKind", "evaluationCriterion", "evaluationValue", "disposition", "branchID", "createdAt", "nonce", "withdrawnRecordID"]
        let sourceKeys: Set<String> = ["url", "title", "quote", "capturedAt", "quoteDigest"]
        for record in records {
            guard Set(record.keys) == ["id", "payload", "signature"], record["id"] is String, record["signature"] is String,
                  let payload = record["payload"] as? [String: Any], Set(payload.keys) == payloadKeys,
                  let source = payload["source"] as? [String: Any], Set(source.keys) == sourceKeys,
                  source.values.allSatisfy({ $0 is String }),
                  payload.filter({ $0.key != "source" }).values.allSatisfy({ $0 is String }) else {
                throw LedgerError.invalidRecord("알 수 없거나 누락된 기록 필드")
            }
        }
    }

    // A bounded preflight, not a replacement JSON parser. Foundation validates syntax afterward.
    // Foundation's ordinary object parser otherwise silently discards duplicate object keys.
    private static func validateJSONKeysAndDepth(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw LedgerError.invalidRecord("UTF-8 형식이 아닙니다") }
        let bytes = Array(data)
        var frames: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                frames.append(byte == 123 ? Set<String>() : nil)
                guard frames.count <= 16 else { throw LedgerError.invalidRecord("JSON 중첩 제한") }
            } else if byte == 125 || byte == 93 {
                guard !frames.isEmpty else { throw LedgerError.invalidRecord("JSON 괄호 형식") }
                frames.removeLast()
            } else if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw LedgerError.invalidRecord("JSON 문자열 형식") }
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    guard !frames.isEmpty, var keys = frames[frames.count - 1],
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])) else {
                        throw LedgerError.invalidRecord("JSON 속성명 형식")
                    }
                    guard keys.insert(key).inserted else { throw LedgerError.invalidRecord("중복 JSON 속성명") }
                    frames[frames.count - 1] = keys
                }
            }
            index += 1
        }
    }
}
