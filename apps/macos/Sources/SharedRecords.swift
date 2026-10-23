import Foundation
import CryptoKit
import Security
import Combine
import HumanBrowserCore

struct SharingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Android wire format is deliberately kept unchanged for cross-client compatibility.
struct SharedRecord: Codable, Identifiable, Equatable {
    let fields: [String: String]
    var id: String { self["id"] }
    subscript(_ key: String) -> String { fields[key] ?? "" }
    init(fields: [String: String]) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: String].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(fields) }
    var kind: RecordKind { RecordKind(rawValue: self["kind"]) ?? .comment }

    static let payloadKeys = Set(["url", "title", "quote", "capturedAt", "kind", "text", "targetId", "criterion", "value", "disposition", "relation", "id", "protocolVersion", "canonicalization", "algorithm", "actorId", "publicKey", "createdAt", "operation", "withdrawnRecordId", "quoteDigest"])
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func timestamp() -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
    static func quoted(_ value: String) -> String {
        var s = "\""
        for c in value.unicodeScalars {
            switch c.value {
            case 34: s += "\\\""
            case 92: s += "\\\\"
            case 47: s += "\\/"
            case 8: s += "\\b"
            case 9: s += "\\t"
            case 10: s += "\\n"
            case 12: s += "\\f"
            case 13: s += "\\r"
            case 0...31: s += String(format: "\\u%04x", c.value)
            default: s.unicodeScalars.append(c)
            }
        }
        return s + "\""
    }
    static func canonical(_ fields: [String: String]) -> String {
        "{" + fields.keys.sorted().map { quoted($0) + ":" + quoted(fields[$0]!) }.joined(separator: ",") + "}"
    }
    static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let u = URLComponents(string: value), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return false }
        return true
    }
    static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    func verified() throws -> SharedRecord {
        func require(_ condition: Bool) throws { if !condition { throw SharingError(message: "공개 기록의 형식 또는 서명 검증에 실패했습니다.") } }
        try require(Set(fields.keys) == Self.payloadKeys.union(["signature", "signedPayload"]))
        for (k, v) in fields {
            let limit = k == "signedPayload" ? 131072 : ["text", "quote"].contains(k) ? 32768 : k == "url" ? 8192 : 2048
            try require(v.utf8.count <= limit && !v.unicodeScalars.contains(where: { $0.value == 0 }))
        }
        let p = fields.filter { Self.payloadKeys.contains($0.key) }
        try require(Self.canonical(p) == self["signedPayload"])
        try require(self["protocolVersion"] == "android-local-alpha/1" && self["canonicalization"] == "android-fixed-string-json/1" && self["algorithm"] == "SHA256withECDSA/P-256")
        try require(Self.isUUID(id) && Self.validURL(self["url"]))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        for k in ["capturedAt", "createdAt"] {
            try require(self[k].hasSuffix("Z") && (f.date(from: self[k]) != nil || basic.date(from: self[k]) != nil))
        }
        try require(self["quoteDigest"] == Self.hash(Data(self["quote"].utf8)))
        guard let der = Data(base64Encoded: self["publicKey"]), der.base64EncodedString() == self["publicKey"],
              let signature = Data(base64Encoded: self["signature"]), signature.base64EncodedString() == self["signature"] else { throw SharingError(message: "공개 기록의 서명 인코딩이 올바르지 않습니다.") }
        let key = try P256.Signing.PublicKey(derRepresentation: der)
        try require(self["actorId"] == "actor:" + Self.hash(der))
        try require(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: Data(self["signedPayload"].utf8)))
        try require(RecordKind(rawValue: self["kind"]) != nil)
        func nonempty(_ key: String) -> Bool { !self[key].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if self["operation"] == "withdrawal" {
            try require(Self.isUUID(self["withdrawnRecordId"]) && ["text", "targetId", "criterion", "value", "disposition", "relation"].allSatisfy { self[$0].isEmpty })
        } else {
            try require(self["operation"] == "record" && self["withdrawnRecordId"].isEmpty)
            try require(![.comment, .question, .answer, .relation].contains(kind) || nonempty("text"))
            try require(kind == .evaluation ? nonempty("criterion") && nonempty("value") : self["criterion"].isEmpty && self["value"].isEmpty)
            try require(self["targetId"].isEmpty || (Self.isUUID(self["targetId"]) && [.answer, .evaluation, .relation].contains(kind)))
            try require(kind == .relation ? nonempty("targetId") && nonempty("relation") : self["relation"].isEmpty)
            try require(kind == .decision ? nonempty("disposition") : self["disposition"].isEmpty)
        }
        return self
    }
    static func sign(draft: RecordDraft, targetID: String = "", key: P256.Signing.PrivateKey,
                     withdrawal: String = "") throws -> SharedRecord {
        var p = Dictionary(uniqueKeysWithValues: payloadKeys.map { ($0, "") })
        p.merge(["id": UUID().uuidString.lowercased(), "url": draft.source.url, "title": draft.source.title,
                 "quote": draft.source.quote, "capturedAt": draft.source.capturedAt, "quoteDigest": hash(Data(draft.source.quote.utf8)),
                 "kind": draft.kind.rawValue, "createdAt": timestamp(), "protocolVersion": "android-local-alpha/1",
                 "canonicalization": "android-fixed-string-json/1", "algorithm": "SHA256withECDSA/P-256",
                 "publicKey": key.publicKey.derRepresentation.base64EncodedString(),
                 "actorId": "actor:" + hash(key.publicKey.derRepresentation),
                 "operation": withdrawal.isEmpty ? "record" : "withdrawal", "withdrawnRecordId": withdrawal]) { _, new in new }
        if withdrawal.isEmpty {
            p.merge(["text": draft.text, "targetId": targetID, "criterion": draft.evaluationCriterion ?? "",
                     "value": draft.evaluationValue ?? "", "disposition": draft.disposition ?? "", "relation": draft.relationKind ?? ""]) { _, new in new }
        }
        let payload = canonical(p)
        p["signedPayload"] = payload
        p["signature"] = try key.signature(for: Data(payload.utf8)).derRepresentation.base64EncodedString()
        return try SharedRecord(fields: p).verified()
    }
}

private enum SharedKeychain {
    static func load(allowCreation: Bool) throws -> P256.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "org.humanbrowser.shared.signing", kSecAttrAccount as String: "p256-v1"]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try P256.Signing.PrivateKey(rawRepresentation: data) }
        guard status == errSecItemNotFound && allowCreation else {
            throw SharingError(message: "공유 서명 키를 읽을 수 없습니다 (\(status)). 기존 신원을 새 키로 교체하지 않았습니다.")
        }
        let key = P256.Signing.PrivateKey()
        var add = query; add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SharingError(message: "공유 키를 키체인에 저장하지 못했습니다 (\(added)).") }
        return try load(allowCreation: false)
    }
}

final class SharedTransport: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SharingError(message: "공유 서버 응답을 확인할 수 없습니다.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw SharingError(message: "공유 응답이 크기 한도를 넘었습니다.") }
            data.append(byte)
        }
        return (data, http)
    }
}

@MainActor
final class SharedStore: ObservableObject {
    struct State: Codable {
        var enabled = false
        var records: [SharedRecord] = []
        var sent: Set<String> = []
        var localIDs: [String: String] = [:]
    }
    @Published private(set) var state: State
    @Published private(set) var records: [SharedRecord] = []
    @Published private(set) var currentURL = ""
    @Published private(set) var nextBefore: Int?
    @Published private(set) var status = "공유 연결을 켜면 현재 URL의 공개 판단을 불러옵니다."
    @Published private(set) var syncing = false
    @Published private(set) var loading = false
    @Published private(set) var sendError: String?
    private let file: URL
    private let transport: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let keyProvider: (Bool) throws -> P256.Signing.PrivateKey
    private let base: URL
    private var key: P256.Signing.PrivateKey?
    private var generation = UUID()
    private var requestID = UUID()
    var pendingCount: Int { state.records.filter { !state.sent.contains($0.id) }.count }
    var pendingHere: [SharedRecord] { state.records.filter { $0["operation"] == "record" && $0["url"] == currentURL && !state.sent.contains($0.id) && !isWithdrawn($0.id) } }
    var enabled: Bool { state.enabled }

    init(directory: URL, base: URL = URL(string: "https://human-browser-production.up.railway.app")!,
         transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil,
         keyProvider: ((Bool) throws -> P256.Signing.PrivateKey)? = nil) throws {
        file = directory.appendingPathComponent("shared-records-v1.json")
        self.base = base
        let network = SharedTransport()
        self.transport = transport ?? { try await network.send($0) }
        self.keyProvider = keyProvider ?? { try SharedKeychain.load(allowCreation: $0) }
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            state = try JSONDecoder().decode(State.self, from: data)
            for record in state.records { _ = try record.verified() }
        } else { state = State() }
    }
    private func commit(_ next: State) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        state = next
    }
    func setEnabled(_ enabled: Bool) {
        do {
            var next = state; next.enabled = enabled; try commit(next)
            if !enabled { generation = UUID(); records = []; nextBefore = nil; status = "공유 연결을 껐습니다. 승인한 전송 대기는 보관됩니다." }
        } catch { status = error.localizedDescription }
    }
    func selectURL(_ url: String) {
        guard currentURL != url else { return }
        generation = UUID(); requestID = UUID(); currentURL = url; records = []; nextBefore = nil; loading = false
        status = SharedRecord.validURL(url) ? "이 페이지의 공개 판단을 기다리는 중입니다." : "HTTP·HTTPS 페이지에서 공유할 수 있습니다."
    }
    private func signingKey() throws -> P256.Signing.PrivateKey {
        if let key { return key }
        let k = try keyProvider(state.records.isEmpty)
        guard state.records.allSatisfy({ $0["publicKey"] == k.publicKey.derRepresentation.base64EncodedString() }) else {
            throw SharingError(message: "공유 저장소와 서명 키가 다릅니다. 신원을 교체하지 않았습니다.")
        }
        key = k; return k
    }
    func owns(_ record: SharedRecord) -> Bool { state.records.contains { $0.id == record.id && $0 == record } }
    func isWithdrawn(_ id: String) -> Bool { state.records.contains { $0["withdrawnRecordId"] == id } }
    func publicID(for localID: String) -> String? { state.localIDs[localID] }
    func publicationStatus(_ localID: String) -> String? {
        guard let id = publicID(for: localID) else { return nil }
        if let w = state.records.first(where: { $0["withdrawnRecordId"] == id }) {
            return state.sent.contains(w.id) ? "공개 철회됨" : "공개 철회 전송 대기"
        }
        return state.sent.contains(id) ? "공개됨" : "공개 전송 대기"
    }
    @discardableResult
    func publish(_ draft: RecordDraft, publicTarget: SharedRecord? = nil, localID: String? = nil) throws -> SharedRecord {
        if let localID, let existing = state.localIDs[localID], let record = state.records.first(where: { $0.id == existing }) { return record }
        var target = ""
        if let id = draft.relationTargetID, !id.isEmpty {
            if let publicTarget, publicTarget.id == id {
                _ = try publicTarget.verified(); target = id
            } else if let mapped = state.localIDs[id], !isWithdrawn(mapped) { target = mapped }
            else { throw SharingError(message: "연결 대상은 아직 공개되지 않았습니다. 대상 기록을 먼저 직접 공개해 주세요.") }
        }
        let record = try SharedRecord.sign(draft: draft, targetID: target, key: signingKey())
        var next = state; next.records.append(record); next.enabled = true
        if let localID { next.localIDs[localID] = record.id }
        try commit(next)
        status = "공개를 승인했습니다. 서버 전송 대기 중입니다."
        return record
    }
    func withdraw(_ record: SharedRecord) throws {
        guard owns(record), record["operation"] == "record" else { throw SharingError(message: "이 기기에서 공개한 기록만 철회할 수 있습니다.") }
        guard !isWithdrawn(record.id) else { return }
        let draft = RecordDraft(source: SourceSnapshot(url: record["url"], title: record["title"], quote: record["quote"]), kind: record.kind, text: "")
        let withdrawal = try SharedRecord.sign(draft: draft, key: signingKey(), withdrawal: record.id)
        var next = state; next.records.append(withdrawal); next.enabled = true
        try commit(next)
        records.removeAll { $0.id == record.id }
        status = "공개 철회 전송 대기 중입니다. 서버 확인 전에는 다른 기기에 보일 수 있습니다."
    }
    func withdrawLocal(_ id: String) throws {
        if let mapped = state.localIDs[id], let original = state.records.first(where: { $0.id == mapped }) { try withdraw(original) }
    }
    func flush() async {
        guard enabled, !syncing else { return }
        syncing = true; defer { syncing = false }
        sendError = nil
        // Insertion order preserves approved target/original dependencies. Stop on the first failure.
        for record in state.records where !state.sent.contains(record.id) {
            guard enabled, !Task.isCancelled else { return }
            do {
                var request = URLRequest(url: base.appendingPathComponent("v1/records"))
                request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(record)
                let (data, response) = try await transport(request)
                guard (200...201).contains(response.statusCode) else { throw SharingError(message: "전송 실패 (HTTP \(response.statusCode)). 승인한 기록은 보관되어 재시도합니다.") }
                struct Ack: Decodable { let id: String }
                let ack = try JSONDecoder().decode(Ack.self, from: data)
                guard ack.id == record.id else { throw SharingError(message: "서버의 기록 확인 번호가 다릅니다. 전송 대기를 유지합니다.") }
                var next = state; next.sent.insert(record.id); try commit(next)
            } catch { sendError = error.localizedDescription; status = "\(error.localizedDescription) · 전송 대기 \(pendingCount)건"; return }
        }
    }
    func refresh(more: Bool = false) async {
        guard enabled, SharedRecord.validURL(currentURL), !loading else { return }
        if more && nextBefore == nil { return }
        let url = currentURL, token = generation, requestToken = UUID()
        requestID = requestToken; loading = true
        defer { if requestID == requestToken { loading = false } }
        do {
            var components = URLComponents(url: base.appendingPathComponent("v1/records"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "url", value: url)]
            if more, let nextBefore { components.queryItems!.append(URLQueryItem(name: "before", value: String(nextBefore))) }
            let (data, response) = try await transport(URLRequest(url: components.url!))
            guard response.statusCode == 200 else { throw SharingError(message: "공개 목록을 불러오지 못했습니다 (HTTP \(response.statusCode)).") }
            struct Page: Decodable { let records: [SharedRecord]; let nextBefore: Int?; let sourceUrl: String }
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard page.sourceUrl == url, page.records.count <= 25, page.nextBefore == nil || page.nextBefore! > 0 else { throw SharingError(message: "공개 목록의 URL 또는 페이지 정보가 올바르지 않습니다.") }
            for r in page.records {
                _ = try r.verified()
                guard r["url"] == url && r["operation"] == "record" else { throw SharingError(message: "다른 페이지의 기록이 섞여 있어 표시하지 않았습니다.") }
            }
            guard token == generation, enabled, !Task.isCancelled else { return }
            var result = more ? records : []
            for r in page.records where !result.contains(where: { $0.id == r.id }) && !isWithdrawn(r.id) { result.append(r) }
            records = result; nextBefore = page.nextBefore
            status = pendingCount == 0 ? "\(Date().formatted(date: .omitted, time: .shortened)) 동기화됨 · 30초마다 갱신" : "목록 갱신됨 · 전송 대기 \(pendingCount)건 (다시 시도 가능)"
        } catch {
            guard token == generation, enabled, !Task.isCancelled else { return }
            status = "\(error.localizedDescription) · 이전 목록은 최신이 아닐 수 있습니다."
        }
    }
    func sync() async { await flush(); await refresh() }
}
