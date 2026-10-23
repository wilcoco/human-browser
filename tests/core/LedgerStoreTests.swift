#if CORE_STANDALONE
typealias CoreTestCase = StandaloneTestCase
#else
import XCTest
typealias CoreTestCase = XCTestCase
#endif
import Foundation
import CryptoKit
@testable import HumanBrowserCore

final class LedgerStoreTests: CoreTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("human-browser-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }
    private func store(signer: (any RecordSigner)? = nil) throws -> LedgerStore {
        try LedgerStore(directory: directory(), signer: signer ?? EphemeralSigner())
    }
    private func draft(_ text: String = "검토 의견", kind: RecordKind = .comment, url: String = "https://example.test/article") -> RecordDraft {
        RecordDraft(source: SourceSnapshot(url: url, title: "원문 제목", quote: "원문 인용", capturedAt: Date(timeIntervalSince1970: 1_700_000_000)), kind: kind, text: text)
    }
    private func archive(_ records: [SignedRecord]) throws -> Data {
        let values = try records.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["format": ProtocolV0.archiveFormat, "records": values], options: [.sortedKeys])
    }
    private func mutate(_ record: SignedRecord, _ body: (inout [String: Any]) -> Void) throws -> SignedRecord {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        body(&object)
        return try JSONDecoder().decode(SignedRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testFrozenSourceAndExplicitCommitBoundary() throws {
        let ledger = try store()
        var pageText = "처음 본 인용"
        let snapshot = SourceSnapshot(url: "https://example.test/a?x=1", title: "처음 제목", quote: pageText)
        let approvedDraft = RecordDraft(source: snapshot, kind: .comment, text: "승인한 의견")
        pageText = "페이지가 나중에 바뀜"
        XCTAssertEqual(try ledger.allRecords().count, 0)
        let record = try ledger.commitDraft(approvedDraft)
        XCTAssertEqual(record.source.quote, "처음 본 인용")
        XCTAssertNotEqual(record.source.quote, pageText)
        XCTAssertEqual(record.source.quoteDigest, ProtocolV0.digest(Data("처음 본 인용".utf8)))
        XCTAssertNoThrow(try LedgerStore.verify(record))
        XCTAssertEqual(try ledger.allRecords().count, 1)
    }

    func testTamperedPayloadAndPublicKeyAreRejectedEvenWithRecomputedID() throws {
        let ledger = try store()
        let original = try ledger.commitDraft(draft())
        let changed = try mutate(original) { record in
            var payload = record["payload"] as! [String: Any]
            payload["text"] = "몰래 바꾼 의견"
            record["payload"] = payload
        }
        let forged = SignedRecord(id: "event:" + ProtocolV0.digest(changed.canonicalPayloadData()), payload: changed.payload, signature: original.signature)
        XCTAssertThrowsError(try LedgerStore.verify(forged))
        let keyChanged = try mutate(original) { record in
            var payload = record["payload"] as! [String: Any]
            payload["publicKey"] = EphemeralSigner().publicKeyData.base64EncodedString()
            record["payload"] = payload
        }
        XCTAssertThrowsError(try LedgerStore.verify(keyChanged))
        XCTAssertThrowsError(try ledger.importData(archive([forged])))
        XCTAssertEqual(try ledger.allRecords().count, 1)
    }

    func testDuplicateImportIsIdempotent() throws {
        let signer = EphemeralSigner()
        let origin = try store(signer: signer)
        let record = try origin.commitDraft(draft())
        let resigned = SignedRecord(id: record.id, payload: record.payload, signature: try signer.sign(record.canonicalPayloadData()).base64EncodedString())
        let destination = try store()
        let first = try destination.importData(archive([record, resigned]))
        XCTAssertEqual(first.inserted, 1)
        XCTAssertEqual(first.duplicates, 1)
        let second = try destination.importData(origin.exportData())
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicates, 1)
        XCTAssertEqual(try destination.activeRecords().count, 1)
    }

    func testWithdrawalBeforeOriginalPreservesHistoryAndAppliesOnlyToTarget() throws {
        let origin = try store()
        let original = try origin.commitDraft(draft("첫 판단"))
        let other = try origin.commitDraft(draft("별개의 판단"))
        let withdrawal = try origin.withdraw(recordID: original.id)
        XCTAssertEqual(try origin.withdraw(recordID: original.id).id, withdrawal.id)
        let destination = try store()
        let pending = try destination.importData(archive([withdrawal]))
        XCTAssertEqual(pending.pendingWithdrawals, 1)
        XCTAssertEqual(try destination.withdrawalStatus(withdrawal), .pendingOriginal)
        XCTAssertFalse(try destination.isWithdrawn(original.id))
        try destination.importData(archive([original, other]))
        XCTAssertEqual(try destination.withdrawalStatus(withdrawal), .authorized)
        XCTAssertTrue(try destination.isWithdrawn(original.id))
        XCTAssertEqual(try destination.activeRecords().map(\.id), [other.id])
        XCTAssertEqual(try destination.allRecords().count, 3)
    }

    func testForeignWithdrawalCannotSuppressOrPreemptOriginal() throws {
        let owner = try store()
        let original = try owner.commitDraft(draft())
        let attackerSigner = EphemeralSigner()
        let attacker = try store(signer: attackerSigner)
        try attacker.importData(archive([original]))
        XCTAssertThrowsError(try attacker.withdraw(recordID: original.id))
        let sample = try attacker.commitDraft(draft("공격자 기록"))
        let rawWithdrawal = try mutate(sample) { record in
            var p = record["payload"] as! [String: Any]
            p["operation"] = "withdrawal"; p["text"] = ""; p["withdrawnRecordID"] = original.id
            record["payload"] = p
        }
        let bytes = rawWithdrawal.canonicalPayloadData()
        let foreign = SignedRecord(id: "event:" + ProtocolV0.digest(bytes), payload: rawWithdrawal.payload, signature: try attackerSigner.sign(bytes).base64EncodedString())
        let destination = try store()
        try destination.importData(archive([foreign]))
        try destination.importData(archive([original]))
        XCTAssertEqual(try destination.withdrawalStatus(foreign), .unauthorized)
        XCTAssertFalse(try destination.isWithdrawn(original.id))
        XCTAssertEqual(try destination.activeRecords().map(\.id), [original.id])
    }

    func testPersistenceReloadAndExactSourceURLFilter() throws {
        let path = try directory()
        let signer = EphemeralSigner()
        var first: LedgerStore? = try LedgerStore(directory: path, signer: signer)
        let a = try first!.commitDraft(draft("첫 주소", url: "https://example.test/a?x=1"))
        _ = try first!.commitDraft(draft("다른 주소", url: "https://example.test/a?x=2"))
        first = nil
        let reopened = try LedgerStore(directory: path, signer: signer)
        XCTAssertEqual(try reopened.allRecords().count, 2)
        XCTAssertEqual(try reopened.allRecords(sourceURL: "https://example.test/a?x=1").map(\.id), [a.id])
        XCTAssertEqual(try reopened.allRecords(sourceURL: "https://example.test/a").count, 0)
        XCTAssertEqual(reopened.actorID, a.actorID)
    }

    func testBadArchiveIsAtomicAndUnknownSchemaIsRejected() throws {
        let origin = try store()
        let good = try origin.commitDraft(draft())
        let bad = try mutate(good) { record in
            var p = record["payload"] as! [String: Any]
            p["protocolVersion"] = "future/99"
            record["payload"] = p
        }
        let destination = try store()
        XCTAssertThrowsError(try destination.importData(archive([good, bad])))
        XCTAssertEqual(try destination.allRecords().count, 0)
        XCTAssertThrowsError(try LedgerStore.verify(bad)) { error in
            guard case LedgerError.unsupportedSchema = error else { return XCTFail("Expected unsupported schema, received \(error)") }
        }
    }

    func testDuplicateUnknownAndDeepJSONFieldsAreRejected() throws {
        let origin = try store()
        _ = try origin.commitDraft(draft())
        let valid = try origin.exportData()
        let destination = try store()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        root["hidden"] = "승인받지 않은 필드"
        XCTAssertThrowsError(try destination.importData(JSONSerialization.data(withJSONObject: root)))
        let string = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let duplicate = string.replacingOccurrences(of: "\"format\" :", with: "\"format\":\"bad\", \"format\" :")
        XCTAssertNotEqual(duplicate, string)
        XCTAssertThrowsError(try destination.importData(Data(duplicate.utf8)))
        XCTAssertThrowsError(try destination.importData(Data((String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20)).utf8)))
        XCTAssertEqual(try destination.allRecords().count, 0)
    }

    func testTypedFieldsAndReasonlessHold() throws {
        let ledger = try store()
        let source = SourceSnapshot(url: "https://example.test/", title: "전체 문서", quote: "")
        let hold = try ledger.commitDraft(RecordDraft(source: source, kind: .decision, text: "", disposition: "hold"))
        XCTAssertEqual(hold.payload.disposition, "hold")
        let evaluation = try ledger.commitDraft(RecordDraft(source: source, kind: .evaluation, text: "", evaluationCriterion: "도입 여부", evaluationValue: "보류"))
        XCTAssertEqual(evaluation.payload.evaluationValue, "보류")
        XCTAssertThrowsError(try ledger.commitDraft(RecordDraft(source: source, kind: .evaluation, text: "설명만 있음")))
        XCTAssertThrowsError(try ledger.commitDraft(RecordDraft(source: source, kind: .comment, text: "  ")))
        XCTAssertThrowsError(try ledger.commitDraft(RecordDraft(source: source, kind: .relation, text: "관계", relationTargetID: "not-an-id", relationKind: "supports")))
        XCTAssertEqual(try ledger.allRecords().count, 2)
    }

    func testLocalFileSourceAndExactAnswerEvaluationTargets() throws {
        let ledger = try store()
        let source = SourceSnapshot(url: "file:///tmp/human-browser-fixture.html", title: "로컬 자료", quote: "예시")
        let question = try ledger.commitDraft(RecordDraft(source: source, kind: .question, text: "검토 질문"))
        let answer = try ledger.commitDraft(RecordDraft(source: source, kind: .answer, text: "검토 답변", relationTargetID: question.id))
        let evaluation = try ledger.commitDraft(RecordDraft(source: source, kind: .evaluation, text: "", relationTargetID: answer.id, evaluationCriterion: "근거", evaluationValue: "보류"))
        XCTAssertEqual(answer.relationTargetID, question.id)
        XCTAssertEqual(evaluation.relationTargetID, answer.id)
        XCTAssertEqual(evaluation.source.url, source.url)
        let destination = try store()
        try destination.importData(ledger.exportData())
        XCTAssertEqual(try destination.allRecords(sourceURL: source.url).count, 3)
        XCTAssertThrowsError(try ledger.commitDraft(RecordDraft(source: source, kind: .comment, text: "댓글", relationTargetID: answer.id)))
    }

    func testKeychainFailureAndMissingExistingKeyNeverFallbackOrReset() throws {
        let denied = StubKeyStorage(.failure(LedgerError.keychain("denied")))
        XCTAssertThrowsError(try KeychainSigner(storage: denied))
        XCTAssertEqual(denied.saveCount, 0)
        let missing = StubKeyStorage(.success(nil))
        XCTAssertThrowsError(try KeychainSigner(storage: missing, allowCreation: false))
        XCTAssertEqual(missing.saveCount, 0)
        let corrupt = StubKeyStorage(.success(Data([1, 2, 3])))
        XCTAssertThrowsError(try KeychainSigner(storage: corrupt))
        XCTAssertEqual(corrupt.saveCount, 0)
        let path = try directory()
        let ledger = try LedgerStore(directory: path, signer: FailingSigner())
        XCTAssertThrowsError(try ledger.commitDraft(draft()))
        XCTAssertEqual(try ledger.allRecords().count, 0)
    }

    func testKnownEd25519AndCanonicalInteroperabilityVector() throws {
        let signer = try EphemeralSigner(privateKeyRawData: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!)
        XCTAssertEqual(signer.publicKeyData.hex, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKeyData)
        let rfcSignature = Data(hex: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")!
        XCTAssertTrue(publicKey.isValidSignature(rfcSignature, for: Data()))
        // Apple deliberately randomizes Ed25519 signatures. Verify compatibility,
        // never identify or deduplicate events by signature byte equality.
        XCTAssertTrue(publicKey.isValidSignature(try signer.sign(Data()), for: Data()))
        let fingerprint = ProtocolV0.digest(signer.publicKeyData)
        let source = SourceSnapshot(url: "https://example.test/vector", title: "한글 e\u{301}", quote: "인용\n\"quote\"\\끝", capturedAt: Date(timeIntervalSince1970: 0))
        let payload = RecordPayload(protocolVersion: ProtocolV0.version, canonicalization: ProtocolV0.canonicalization,
            actorID: "actor:" + fingerprint, keyID: "key:" + fingerprint, publicKey: signer.publicKeyData.base64EncodedString(),
            operation: .record, kind: .comment, source: source, text: "줄\t탭\u{0001}", relationTargetID: "", relationKind: "",
            evaluationCriterion: "", evaluationValue: "", disposition: "", branchID: "main",
            createdAt: "1970-01-01T00:00:00.000Z", nonce: "00112233445566778899aabbccddeeff", withdrawnRecordID: "")
        let bytes = ProtocolV0.canonicalData(payload)
        let record = SignedRecord(id: "event:" + ProtocolV0.digest(bytes), payload: payload, signature: try signer.sign(bytes).base64EncodedString())
        XCTAssertNoThrow(try LedgerStore.verify(record))
        let roundtrip = try JSONDecoder().decode(SignedRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundtrip.canonicalPayloadData(), bytes)
        let canonical = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(canonical.contains("\\u0001"))
        XCTAssertNotNil(bytes.range(of: Data("e\u{301}".utf8)))
        XCTAssertNil(bytes.range(of: Data("é".utf8)))
        if let output = ProcessInfo.processInfo.environment["HB_CORE_VECTOR_OUTPUT"] {
            let recordObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
            let fixture: [String: Any] = ["record": recordObject, "canonicalUTF8": canonical, "canonicalBase64": bytes.base64EncodedString(), "eventID": record.id]
            let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

private final class StubKeyStorage: KeyMaterialStorage {
    let result: Result<Data?, Error>
    var saveCount = 0
    init(_ result: Result<Data?, Error>) { self.result = result }
    func load() throws -> Data? { try result.get() }
    func save(_ data: Data) throws { saveCount += 1 }
}
private final class FailingSigner: RecordSigner {
    private let inner = EphemeralSigner()
    var publicKeyData: Data { inner.publicKeyData }
    func sign(_ data: Data) throws -> Data { throw LedgerError.keychain("signing unavailable") }
}
private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
