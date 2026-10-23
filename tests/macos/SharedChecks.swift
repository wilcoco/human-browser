import Foundation
import CryptoKit
import HumanBrowserCore

@MainActor
final class FakeSharedServer {
    var records: [SharedRecord] = []
    var online = true
    var posts: [String] = []
    var overridePage: Data?
    var failAck = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard online else { throw SharingError(message: "offline test") }
        let data: Data
        if request.httpMethod == "POST" {
            let r = try JSONDecoder().decode(SharedRecord.self, from: request.httpBody!).verified()
            posts.append(r.id)
            if !records.contains(where: { $0.id == r.id }) { records.append(r) }
            if failAck { throw SharingError(message: "response lost after acceptance") }
            data = try JSONSerialization.data(withJSONObject: ["id": r.id])
        } else if let overridePage { data = overridePage }
        else {
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "url" }!.value!
            let withdrawn = Set(records.filter { $0["operation"] == "withdrawal" }.map { $0["withdrawnRecordId"] })
            data = try JSONSerialization.data(withJSONObject: ["sourceUrl": url, "nextBefore": NSNull(), "records": records.filter { $0["url"] == url && $0["operation"] == "record" && !withdrawn.contains($0.id) }.map(\.fields)])
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct SharedChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("human-browser-shared-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw SharingError(message: "FAIL: " + name) }
            passed += 1; print("PASS: " + name)
        }
        let key = P256.Signing.PrivateKey()
        let url = "https://example.org/shared-test?query=한글&path=/a#section"
        let draft = RecordDraft(source: SourceSnapshot(url: url, title: "한글 / title", quote: "인용 \"quote\" / 😀\n\t\u{2028}"), kind: .comment, text: "합성 검사 / 사람의 의견 아님 😀")
        let signed = try SharedRecord.sign(draft: draft, key: key)
        try check(tryValid(signed), "P-256 signed canonical payload")
        var tampered = signed.fields; tampered["text"] = "tampered"
        try check(!tryValid(SharedRecord(fields: tampered)), "tampered body rejected")
        tampered = signed.fields; tampered["actorId"] = "actor:wrong"
        try check(!tryValid(SharedRecord(fields: tampered)), "identity substitution rejected")
        try check(!SharedRecord.validURL("file:///private/test") && !SharedRecord.validURL("https://a:b@example.org") && !SharedRecord.validURL("https://example.org/ bad"), "private-file credential whitespace URLs rejected")
        struct AndroidArchive: Decodable { let records: [SharedRecord] }
        let android = try JSONDecoder().decode(AndroidArchive.self, from: Data(contentsOf: URL(fileURLWithPath: "tests/api/android-fixture.json"))).records[0]
        try check(tryValid(android), "actual Android fixture verified by Swift")
        let fixtureFile = URL(fileURLWithPath: "work/macos-shared-fixture.json")
        try JSONEncoder().encode(signed).write(to: fixtureFile)
        let server = FakeSharedServer()
        let store = try SharedStore(directory: root, transport: { try await server.send($0) }, keyProvider: { _ in key })
        try check(!store.enabled && store.pendingCount == 0, "first launch sends no draft or URL")
        server.online = false
        let original = try store.publish(draft, localID: "local-original")
        let repeated = try store.publish(draft, localID: "local-original")
        try check(original.id == repeated.id && store.pendingCount == 1, "publish maps local record once")
        store.selectURL(url)
        await store.sync()
        try check(store.pendingCount == 1, "offline approved record retained")
        let restored = try SharedStore(directory: root, transport: { try await server.send($0) }, keyProvider: { allowed in
            if allowed { throw SharingError(message: "must not replace existing identity") }; return key
        })
        try check(restored.state.records == store.state.records && restored.pendingCount == 1, "restart preserves exact envelope and queue")
        server.online = true; server.failAck = true
        await restored.flush()
        try check(restored.pendingCount == 1 && server.records.count == 1, "lost acknowledgment remains retryable")
        server.failAck = false
        await restored.flush()
        try check(restored.pendingCount == 0 && server.records.count == 1 && server.posts == [original.id, original.id], "retry is idempotent")
        restored.selectURL(url); await restored.refresh()
        try check(restored.records == [original], "matching page displays verified shared record")
        restored.selectURL("https://example.org/other")
        try check(restored.records.isEmpty, "navigation clears previous URL immediately")
        await restored.refresh()
        try check(restored.records.isEmpty, "exact URL isolation")
        let evaluation = RecordDraft(source: draft.source, kind: .evaluation, text: "평가 검사", relationTargetID: original.id, evaluationCriterion: "근거 충분성", evaluationValue: "판단 어려움")
        let evaluated = try restored.publish(evaluation, publicTarget: original)
        try check(evaluated["targetId"] == original.id, "public evaluation keeps exact target UUID")
        let localAnswer = RecordDraft(source: draft.source, kind: .answer, text: "답변 검사", relationTargetID: "local-original")
        let answer = try restored.publish(localAnswer)
        try check(answer["targetId"] == original.id, "local target converted to published UUID")
        let invalidTarget = RecordDraft(source: draft.source, kind: .answer, text: "no", relationTargetID: "not-approved")
        var rejected = false
        do { _ = try restored.publish(invalidTarget) } catch { rejected = true }
        try check(rejected, "unpublished target is never silently published")
        server.online = false
        try restored.withdraw(original)
        try restored.withdraw(original)
        await restored.flush()
        try check(restored.state.records.filter { $0["operation"] == "withdrawal" }.count == 1, "withdrawal queued exactly once offline")
        server.online = true
        await restored.flush()
        restored.selectURL(url); await restored.refresh()
        try check(!restored.records.contains(where: { $0.id == original.id }) && restored.records.contains(where: { $0.id == evaluated.id }), "withdrawal hides original and retains others' evaluation")
        let foreign = try SharedRecord.sign(draft: draft, key: P256.Signing.PrivateKey())
        rejected = false
        do { try restored.withdraw(foreign) } catch { rejected = true }
        try check(rejected, "foreign-owner withdrawal blocked")
        server.overridePage = try JSONSerialization.data(withJSONObject: ["sourceUrl": url, "nextBefore": NSNull(), "records": [tampered]])
        let before = restored.records
        await restored.refresh()
        try check(restored.records == before && restored.status.contains("최신"), "bad page is rejected atomically and marked stale")
        server.overridePage = try JSONSerialization.data(withJSONObject: ["sourceUrl": "https://wrong.test/", "nextBefore": NSNull(), "records": []])
        await restored.refresh()
        try check(restored.records == before, "wrong response URL rejected")
        restored.setEnabled(false)
        try check(restored.records.isEmpty && !restored.enabled, "disconnect clears shared list")
        let wrongKey = try SharedStore(directory: root, transport: { try await server.send($0) }, keyProvider: { _ in P256.Signing.PrivateKey() })
        rejected = false
        do { _ = try wrongKey.publish(draft) } catch { rejected = true }
        try check(rejected, "existing shared identity cannot silently change")
        // A delayed old-page response must not replace the new page after navigation.
        let raceDir = root.appendingPathComponent("race"); try FileManager.default.createDirectory(at: raceDir, withIntermediateDirectories: true)
        let race = try SharedStore(directory: raceDir, transport: { request in
            try await Task.sleep(for: .milliseconds(80))
            let data = try JSONSerialization.data(withJSONObject: ["sourceUrl": url, "nextBefore": NSNull(), "records": [signed.fields]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, keyProvider: { _ in key })
        race.setEnabled(true); race.selectURL(url)
        let task = Task { await race.refresh() }
        try await Task.sleep(for: .milliseconds(10))
        race.selectURL("https://example.org/new")
        await task.value
        try check(race.records.isEmpty && race.currentURL.hasSuffix("/new"), "late response cannot cross navigation boundary")
        print("Shared checks passed: \(passed)")
    }
    static func tryValid(_ r: SharedRecord) -> Bool { (try? r.verified()) != nil }
}
