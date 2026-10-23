import SwiftUI
import HumanBrowserCore

struct SharedPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shared: SharedStore
    @ObservedObject var tab: BrowserTab
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("함께 보는 판단").font(.system(size: 17, weight: .semibold))
            Toggle("공유 연결 · 현재 URL을 서버에 전송", isOn: Binding(get: { shared.enabled }, set: { shared.setEnabled($0) }))
                .font(.system(size: 11))
            Text("맥·안드로이드에서 같은 URL의 공개 기록을 봅니다. 개인 초안은 자동 공개하지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if shared.enabled {
                HStack {
                    if shared.loading || shared.syncing { ProgressView().controlSize(.small) }
                    Text(shared.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("새로고침·재시도") { Task { await shared.sync() } }
                        .font(.system(size: 10)).disabled(shared.loading || shared.syncing)
                }
                if let error = shared.sendError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                }
                if shared.pendingCount > 0 {
                    Text("전송 대기 \(shared.pendingCount)건 · 앱을 다시 열어도 승인한 요청을 재시도합니다.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                ForEach(shared.pendingHere.filter { $0["url"] == tab.currentURL }) { r in
                    SharedRecordCard(record: r, model: model, shared: shared, pending: true)
                }
                if shared.records.isEmpty && !shared.loading {
                    Text("이 URL에 표시할 공개 기록이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(shared.records.filter { $0["url"] == tab.currentURL }) { r in
                    SharedRecordCard(record: r, model: model, shared: shared, pending: false)
                }
                if shared.nextBefore != nil {
                    Button("이전 공개 기록 더 보기") { Task { await shared.refresh(more: true) } }
                        .disabled(shared.loading).font(.system(size: 11))
                }
            } else {
                Text("연결을 켜면 페이지 이동 시 자동으로 연동됩니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(tab.id)|\(tab.currentURL)|\(shared.enabled)") {
            shared.selectURL(tab.currentURL)
            guard shared.enabled else { return }
            while !Task.isCancelled {
                await shared.sync()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}

struct SharedRecordCard: View {
    let record: SharedRecord
    @ObservedObject var model: AppModel
    @ObservedObject var shared: SharedStore
    let pending: Bool
    @State private var confirmWithdraw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label(record.kind)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(pending ? "전송 대기" : "공개 · 서명 검증됨").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if !record["quote"].isEmpty { Text(record["quote"]).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4) }
            if record.kind == .evaluation { Text("\(record["criterion"]) · \(record["value"])").font(.system(size: 12, weight: .semibold)) }
            if !record["disposition"].isEmpty { Text(record["disposition"]).font(.system(size: 12, weight: .semibold)) }
            if !record["relation"].isEmpty { Text(record["relation"]).font(.system(size: 12, weight: .semibold)) }
            if !record["targetId"].isEmpty {
                Text("대상 \(record["targetId"])").font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
            }
            Text(record["text"]).font(.system(size: 13)).textSelection(.enabled)
            Text("기기 키 \(record["actorId"].prefix(18))… · \(record["createdAt"])")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Button("답변") { model.targetPublic(record, kind: .answer) }
                Button("평가") { model.targetPublic(record, kind: .evaluation) }
                Button("연결") { model.targetPublic(record, kind: .relation) }
                Spacer()
                if shared.owns(record) {
                    Button("공개 철회", role: .destructive) { confirmWithdraw = true }
                }
            }.font(.system(size: 10)).buttonStyle(.borderless)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("공개를 철회할까요? 서버 반영 후 목록에서 숨겨집니다. 이미 복사된 내용과 철회 이력은 남습니다.", isPresented: $confirmWithdraw) {
            Button("공개 철회", role: .destructive) { model.withdrawPublic(record) }
            Button("취소", role: .cancel) {}
        }
    }
}
