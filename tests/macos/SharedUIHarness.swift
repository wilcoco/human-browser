import AppKit
import SwiftUI
import CryptoKit
import HumanBrowserCore

/// Isolated UI harness. All shared API requests stay in memory; browsing example.com is real.
@MainActor final class UISharedServer {
    var records: [SharedRecord]
    init() throws {
        records = [try SharedRecord.sign(draft: RecordDraft(source: SourceSnapshot(url: "https://example.com/", title: "Example Domain", quote: "Example Domain"), kind: .question, text: "합성 UI 검사: 이 페이지에 관해 함께 판단할 근거는 무엇인가요?"), key: P256.Signing.PrivateKey())]
    }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "POST" {
            let record = try JSONDecoder().decode(SharedRecord.self, from: request.httpBody!).verified()
            if !records.contains(where: { $0.id == record.id }) { records.append(record) }
            data = try JSONSerialization.data(withJSONObject: ["id": record.id])
        } else {
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "url" }!.value!
            let withdrawn = Set(records.map { $0["withdrawnRecordId"] })
            data = try JSONSerialization.data(withJSONObject: ["sourceUrl": url, "nextBefore": NSNull(), "records": records.filter { $0["url"] == url && $0["operation"] == "record" && !withdrawn.contains($0.id) }.map(\.fields)])
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@main struct SharedUIHarness: App {
    @NSApplicationDelegateAdaptor(ActivationDelegate.self) var delegate
    @StateObject var model: AppModel
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-shared-ui-" + UUID().uuidString)
        let key = P256.Signing.PrivateKey()
        let server = try! UISharedServer()
        let m = AppModel(directoryOverride: root, signer: EphemeralSigner(), sharingFactory: { directory in
            try SharedStore(directory: directory, transport: { try server.send($0) }, keyProvider: { _ in key })
        })
        m.shared?.setEnabled(true)
        m.selectedTab?.navigate("https://example.com/")
        _model = StateObject(wrappedValue: m)
    }
    var body: some Scene {
        WindowGroup("공유 UI 검사 · 합성 데이터") {
            BrowserRootView(model: model).frame(minWidth: 1060, minHeight: 700).preferredColorScheme(.light)
        }.defaultSize(width: 1440, height: 920).windowStyle(.hiddenTitleBar)
    }
}
