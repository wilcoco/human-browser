import Foundation
import CryptoKit
import HumanBrowserCore

/// Opt-in integration test: posts explicitly labeled synthetic records on a unique .invalid URL,
/// then withdraws them. Never uses the app's Keychain identity or the user's data directory.
@main struct LiveSharingChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-live-shared-" + UUID().uuidString)
        let firstDir = root.appendingPathComponent("first"), secondDir = root.appendingPathComponent("second")
        for dir in [firstDir, secondDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // Retain only if cleanup fails, so the same signed withdrawal can be retried.
        let firstKey = P256.Signing.PrivateKey(), secondKey = P256.Signing.PrivateKey()
        let first = try SharedStore(directory: firstDir, keyProvider: { _ in firstKey })
        let second = try SharedStore(directory: secondDir, keyProvider: { _ in secondKey })
        let url = "https://human-browser.invalid/validation/macos-sharing/" + UUID().uuidString.lowercased()
        first.selectURL(url); second.selectURL(url); second.setEnabled(true)
        let draft = RecordDraft(source: SourceSnapshot(url: url, title: "macOS sharing automated validation (synthetic)", quote: "검사 전용 / real user opinion 아님"), kind: .question, text: "자동화 합성 기록: 맥 공유 전송과 조회 검사. 실제 사람의 판단이 아닙니다.")
        let original = try first.publish(draft)
        var evaluated: SharedRecord?
        var failure: Error?
        do {
            await first.flush()
            guard first.pendingCount == 0 else { throw SharingError(message: first.status) }
            await second.refresh()
            guard second.records.contains(where: { $0.id == original.id }) else { throw SharingError(message: "Second client cannot read first: " + second.status) }
            print("PASS live: signed Mac question published; independent client read and verified it")
            evaluated = try second.publish(RecordDraft(source: draft.source, kind: .evaluation, text: "자동화 합성 평가: 실제 사람의 평가 아님", relationTargetID: original.id, evaluationCriterion: "프로토콜 검증", evaluationValue: "테스트"), publicTarget: original)
            await second.flush(); await first.refresh()
            guard second.pendingCount == 0, first.records.contains(where: { $0.id == evaluated!.id }) else { throw SharingError(message: "Reverse sync failed") }
            print("PASS live: another key's evaluation linked and synced back")
            try first.withdraw(original); await first.flush(); await second.refresh()
            guard first.pendingCount == 0, !second.records.contains(where: { $0.id == original.id }), second.records.contains(where: { $0.id == evaluated!.id }) else { throw SharingError(message: "Withdrawal sync failed") }
            print("PASS live: owner withdrawal hidden on second client, other evaluation retained")
        } catch { failure = error }
        try first.withdraw(original)
        if let evaluated { try second.withdraw(evaluated) }
        await first.flush(); await second.flush(); await first.refresh()
        guard first.pendingCount == 0 && second.pendingCount == 0 && first.records.isEmpty else {
            throw SharingError(message: "Cleanup requires retry using signed outboxes at " + root.path)
        }
        try FileManager.default.removeItem(at: root)
        print("PASS live: all synthetic records withdrawn; public list empty")
        if let failure { throw failure }
    }
}
