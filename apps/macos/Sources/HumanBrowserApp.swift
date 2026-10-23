import AppKit
import SwiftUI
import WebKit
import HumanBrowserCore
import Combine

private enum Theme {
    static let paper = Color(red: 0.965, green: 0.961, blue: 0.941)
    static let ink = Color(red: 0.14, green: 0.22, blue: 0.20)
    static let accent = Color(red: 0.16, green: 0.40, blue: 0.33)
}

struct ReviewItem: Identifiable {
    let id = UUID()
    let draft: RecordDraft
    let targetRecord: SignedRecord?
}

private struct LocalDraft: Codable {
    var source: SourceSnapshot
    var kind: RecordKind
    var text: String
    var criterion: String
    var evaluation: String
    var disposition: String
    var relation: String
    var targetID: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var records: [SignedRecord] = []
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var storageReady = false
    @Published var draftSource: SourceSnapshot?
    @Published var draftKind: RecordKind = .comment
    @Published var draftText = ""
    @Published var criterion = "도움 정도"
    @Published var evaluation = "긍정"
    @Published var disposition = "보류"
    @Published var relation = "근거로 연결"
    @Published var targetID: String?
    @Published var review: ReviewItem?
    @Published var showAllRecords = false
    @Published var ledgerRevision = 0
    @Published var showDraftReset = false
    private var ledger: LedgerStore?
    private var draftGeneration = UUID()
    private var capturePending = false
    private var draftFile: URL?
    private var draftObservation: AnyCancellable?
    private var lastDraftData: Data?

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    init(directoryOverride: URL? = nil, signer: (any RecordSigner)? = nil) {
        do {
            let path = Bundle.main.object(forInfoDictionaryKey: "HBDevelopmentDataDirectory") as? String
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = directoryOverride ?? path.map { URL(fileURLWithPath: $0) } ??
                support.appendingPathComponent("org.humanbrowser.alpha", isDirectory: true)
            ledger = try LedgerStore(directory: directory, signer: signer)
            draftFile = directory.appendingPathComponent("unapproved-draft.json")
            try restoreDraft()
            storageReady = true
            refresh()
        } catch {
            errorMessage = "기록 저장소를 열지 못했습니다. 브라우징은 계속할 수 있습니다.\n\(error.localizedDescription)"
        }
        addTab()
        draftObservation = objectWillChange
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] in self?.persistDraft() }
    }

    private func restoreDraft() throws {
        guard let file = draftFile, FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file)
        let draft = try JSONDecoder().decode(LocalDraft.self, from: data)
        draftSource = draft.source; draftKind = draft.kind; draftText = draft.text
        criterion = draft.criterion; evaluation = draft.evaluation
        disposition = draft.disposition; relation = draft.relation; targetID = draft.targetID
        lastDraftData = data
        notice = "이전에 작성하던 초안을 불러왔습니다. 아직 승인한 기록은 아닙니다."
    }

    func persistDraft() {
        guard let file = draftFile else { return }
        do {
            guard let source = draftSource else {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                lastDraftData = nil
                return
            }
            let draft = LocalDraft(source: source, kind: draftKind, text: draftText, criterion: criterion,
                                   evaluation: evaluation, disposition: disposition, relation: relation, targetID: targetID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(draft)
            guard data != lastDraftData else { return }
            try data.write(to: file, options: .atomic)
            lastDraftData = data
        } catch {
            let message = "초안을 보관하지 못했습니다: \(error.localizedDescription)"
            if errorMessage != message { errorMessage = message }
        }
    }

    func addTab(url: URL? = nil) {
        let tab = BrowserTab(onOpenTab: { [weak self] next in self?.addTab(url: next) })
        tabs.append(tab)
        selectedTabID = tab.id
        if let url { tab.navigate(url.absoluteString) }
    }

    func closeTab(_ tab: BrowserTab) {
        tab.stop()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { addTab() }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }

    func beginPageRecord() async {
        await captureSource(requireSelection: false)
    }

    func capture() async {
        await captureSource(requireSelection: true)
    }

    private func captureSource(requireSelection: Bool) async {
        guard let tab = selectedTab else { return }
        guard !capturePending else { return }
        guard draftSource == nil else {
            notice = "현재 기록은 처음 선택한 자료에 연결됩니다. 다른 문장을 가져오려면 ‘새 기록’을 눌러주세요."
            return
        }
        let generation = draftGeneration
        capturePending = true
        defer { capturePending = false }
        do {
            let captured = try await tab.captureSelection(requireSelection: requireSelection)
            guard generation == draftGeneration, draftSource == nil else { return }
            draftSource = SourceSnapshot(url: captured.url, title: captured.title,
                                         quote: captured.quote, capturedAt: captured.capturedAt)
            notice = "출처를 초안에 고정했습니다. 초안은 이 기기에 보관하며, 승인·공유한 기록은 아닙니다."
        } catch { errorMessage = error.localizedDescription }
    }

    func resetDraft() {
        draftGeneration = UUID()
        draftSource = nil
        draftText = ""
        draftKind = .comment
        targetID = nil
        disposition = "보류"
        criterion = "도움 정도"
        evaluation = "긍정"
        relation = "근거로 연결"
        notice = nil
    }

    func target(_ record: SignedRecord, kind: RecordKind) {
        if kind == .relation, draftSource != nil {
            draftGeneration = UUID()
            targetID = record.id
            draftKind = .relation
            notice = "초안의 출처와 내용은 유지하고, 연결할 기록을 선택했습니다."
            return
        }
        guard draftSource == nil && draftText.isEmpty else {
            notice = "작성 중인 내용을 먼저 저장하거나 ‘새 기록’으로 정리해 주세요."
            return
        }
        draftGeneration = UUID()
        draftSource = record.source
        targetID = record.id
        draftKind = kind
        showAllRecords = false
    }

    func prepareReview() {
        guard storageReady, let source = draftSource else { return }
        guard draftText.count <= 4000 else { errorMessage = "기록은 4,000자 이내로 작성해 주세요."; return }
        if draftKind != .evaluation && draftKind != .decision &&
            draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "기록할 내용을 입력해 주세요."
            return
        }
        if draftKind == .relation && targetID == nil {
            errorMessage = "기록 카드의 ‘연결’에서 연결할 대상을 선택해 주세요."
            return
        }
        review = ReviewItem(draft: RecordDraft(
            source: source, kind: draftKind, text: draftText,
            relationTargetID: [.relation, .answer, .evaluation].contains(draftKind) ? targetID : nil,
            relationKind: draftKind == .relation ? relation : nil,
            evaluationCriterion: draftKind == .evaluation ? criterion : nil,
            evaluationValue: draftKind == .evaluation ? evaluation : nil,
            disposition: draftKind == .decision ? disposition : nil
        ), targetRecord: records.first { $0.id == targetID })
    }

    func saveReviewed(_ item: ReviewItem) {
        guard review?.id == item.id, let ledger else { return }
        do {
            _ = try ledger.commitDraft(item.draft)
            review = nil
            resetDraft()
            persistDraft()
            refresh()
            notice = "이 기기에 저장했습니다. 외부로 전송하지 않았습니다."
        } catch { errorMessage = "저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func refresh() {
        do {
            records = try ledger?.activeRecords() ?? []
            ledgerRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func withdraw(_ record: SignedRecord) {
        guard let ledger else { return }
        do {
            _ = try ledger.withdraw(recordID: record.id)
            refresh()
            notice = "승인을 철회했습니다. 원기록과 철회 이력은 보존됩니다."
        } catch { errorMessage = error.localizedDescription }
    }

    func exportRecords() {
        guard let ledger else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "human-browser-records.json"
        panel.message = "원문 주소와 선택 문장이 포함됩니다. 파일을 다른 사람에게 전달하면 그 내용도 함께 전달됩니다."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ledger.exportData().write(to: url, options: .atomic)
                notice = "서명된 기록을 파일로 내보냈습니다."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func importRecords() {
        guard let ledger else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "이 개발판에서 내보낸 기록을 검증한 뒤 가져옵니다. 기존 기록은 덮어쓰지 않습니다."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 8 * 1024 * 1024 else {
                    throw NSError(domain: "Import", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "가져올 파일은 8MiB 이하여야 합니다."])
                }
                _ = try ledger.importData(Data(contentsOf: url))
                refresh()
                notice = "기록을 검증해 가져왔습니다. 같은 원기록은 중복 저장하지 않습니다."
            } catch { errorMessage = "가져오지 못했습니다: \(error.localizedDescription)" }
        }
    }

    func loadExample() {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/welcome-example.html")
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/fixtures/welcome-example.html")
        guard let tab = selectedTab else { return }
        let url = resource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback
        tab.loadFixture(url)
    }
}

#if !BROWSER_SMOKE_TEST
@main
struct HumanBrowserApplication: App {
    @NSApplicationDelegateAdaptor(ActivationDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            BrowserRootView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 탭") { model.addTab() }.keyboardShortcut("t")
                Button("현재 탭 닫기") {
                    if let tab = model.selectedTab { model.closeTab(tab) }
                }.keyboardShortcut("w")
            }
            CommandMenu("기록") {
                Button("선택 문장 가져오기") { Task { await model.capture() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("기록 내보내기") { model.exportRecords() }
                Button("기록 가져오기") { model.importRecords() }
            }
        }
    }
}
#endif

final class ActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BrowserRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 23)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("사람 브라우저").font(.system(size: 15, weight: .semibold))
                    Text("읽고, 생각하고, 함께 정리하는 곳").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("로컬 개발판", systemImage: "laptopcomputer")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Menu {
                    Button("합성 기사로 사용해 보기", action: model.loadExample)
                    Divider()
                    Button("기록 내보내기", action: model.exportRecords).disabled(!model.storageReady)
                    Button("기록 가져오기", action: model.importRecords).disabled(!model.storageReady)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).frame(width: 26)
            }
            .padding(.leading, 78).padding(.trailing, 18).frame(height: 62)
            .background(Theme.paper)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(model.tabs) { tab in
                                TabButton(tab: tab, isSelected: model.selectedTabID == tab.id,
                                          select: { model.selectedTabID = tab.id },
                                          close: { model.closeTab(tab) })
                            }
                            Button { model.addTab() } label: {
                                Image(systemName: "plus").frame(width: 28, height: 28)
                            }.buttonStyle(.plain).help("새 탭")
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                    }.background(Color.white.opacity(0.65))
                    if let tab = model.selectedTab {
                        BrowserArea(tab: tab, model: model).id(tab.id)
                    }
                }.frame(minWidth: 580)
                if let tab = model.selectedTab {
                    JudgmentPanel(model: model, tab: tab)
                        .frame(minWidth: 355, idealWidth: 405, maxWidth: 540)
                }
            }
            Divider()
            HStack {
                Label("웹 세션은 종료 시 초기화됩니다", systemImage: "eye.slash")
                Spacer()
                Text("판단 기록은 이 기기에 보관 · 공유와 AI 전송 없음")
                Circle().fill(model.storageReady ? Theme.accent : .orange).frame(width: 6, height: 6)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 28).background(Theme.paper)
        }
        .foregroundStyle(Theme.ink)
        .sheet(item: $model.review) { item in ReviewSheet(item: item, model: model) }
        .alert("확인해 주세요", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("확인", role: .cancel) { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("작성 중인 내용을 지우고 새 기록을 시작할까요?", isPresented: $model.showDraftReset) {
            Button("새 기록 시작", role: .destructive) { model.resetDraft() }
            Button("계속 작성", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.persistDraft()
        }
    }
}

struct TabButton: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.isLoading ? "arrow.trianglehead.2.clockwise" : "globe")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(tab.title.isEmpty ? "새 탭" : tab.title).font(.system(size: 11))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).help("탭 닫기")
        }
        .padding(.horizontal, 10).frame(width: 175, height: 29)
        .background(isSelected ? Color.white : Theme.paper.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Theme.accent.opacity(0.25) : .clear))
        .contentShape(Rectangle()).onTapGesture(perform: select)
    }
}

struct BrowserArea: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var model: AppModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Button(action: tab.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack).help("뒤로")
                Button(action: tab.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward).help("앞으로")
                Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }.help(tab.isLoading ? "로딩 중지" : "새로고침")
                HStack(spacing: 8) {
                    Image(systemName: tab.currentURL.hasPrefix("https://") ? "lock" : "globe")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("주소 입력 또는 검색", text: $address)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .focused($addressFocused)
                        .onSubmit { tab.navigate(address); addressFocused = false }
                        .accessibilityLabel("주소 입력 또는 검색")
                }
                .padding(.horizontal, 11).frame(height: 34)
                .background(Theme.paper).clipShape(RoundedRectangle(cornerRadius: 8))
                Button { Task { await model.capture() } } label: {
                    Image(systemName: "quote.bubble").font(.system(size: 15))
                }.help("선택한 문장을 판단 도구로 가져오기")
            }
            .buttonStyle(.plain).padding(.horizontal, 15).padding(.vertical, 10)
            .background(Color.white)
            if tab.isLoading {
                ProgressView(value: tab.estimatedProgress).progressViewStyle(.linear)
                    .tint(Theme.accent).frame(height: 2)
            } else { Divider() }
            if let error = tab.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.system(size: 11)).lineLimit(3)
                    Spacer()
                }.foregroundStyle(.orange).padding(10).background(Color.orange.opacity(0.05))
            }
            ZStack {
                NativeWebView(webView: tab.webView)
                if tab.currentURL.isEmpty || tab.currentURL == "about:blank" {
                    WelcomeView(openExample: model.loadExample, focusAddress: { addressFocused = true })
                }
            }
        }
        .onAppear { address = tab.currentURL == "about:blank" ? "" : tab.currentURL }
        .onChange(of: tab.currentURL) { new in
            if !addressFocused { address = new == "about:blank" ? "" : new }
        }
        .background(.white)
    }
}

struct NativeWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WelcomeView: View {
    let openExample: () -> Void
    let focusAddress: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Label("사람의 생각이 이어지는 탐색", systemImage: "circle.grid.cross")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            Text("읽는 것에서,\n판단을 남기는 것으로.")
                .font(.system(size: 39, weight: .semibold)).tracking(-1.5).lineSpacing(5)
            Text("웹을 둘러보고 마음에 걸리는 문장을 가져오세요.\n질문과 근거를 연결하고, 아직 모르겠다면 보류해도 됩니다.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(7)
            HStack(spacing: 12) {
                Button("주소 입력하고 시작", action: focusAddress)
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                Button("예시 기사 열기", action: openExample)
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Divider().padding(.vertical, 5)
            HStack(alignment: .top, spacing: 28) {
                welcomeStep("01", "읽기", "익숙한 웹을 그대로")
                welcomeStep("02", "생각 남기기", "인용·댓글·평가를 직접")
                welcomeStep("03", "정리하기", "결정과 보류 모두 기록")
            }
            Text("개발판 · 로컬 저장만 제공 · 인간 고유성이나 사실성을 인증하지 않습니다")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 15)
        }
        .padding(45).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Theme.paper)
    }
    private func welcomeStep(_ n: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(n).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct JudgmentPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tab: BrowserTab
    var filtered: [SignedRecord] {
        model.records.filter { model.showAllRecords || $0.source.url == tab.currentURL }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("나의 판단 공간").font(.system(size: 20, weight: .semibold))
                        Text("내가 확인하고 남긴 기록").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "square.and.pencil").font(.system(size: 20)).foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("지금 보고 있는 페이지").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(tab.title.isEmpty ? "페이지를 열어 주세요" : tab.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(tab.currentURL).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 10))

                if let source = model.draftSource {
                    composer(source)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("이 페이지에 어떤 생각이 있나요?").font(.system(size: 13, weight: .medium))
                        Button { Task { await model.beginPageRecord() } } label: {
                            Label("페이지에 의견 남기기", systemImage: "plus.bubble")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                        Button { Task { await model.capture() } } label: {
                            Label("선택한 문장 가져오기", systemImage: "text.quote")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large)
                        Text("페이지에서 문장을 선택한 뒤 가져오세요.\n저장하기 전까지는 초안입니다.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                }
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack {
                    Text("기록").font(.system(size: 14, weight: .semibold))
                    Text("\(filtered.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("기록 범위", selection: $model.showAllRecords) {
                        Text("현재 페이지").tag(false)
                        Text("전체").tag(true)
                    }.labelsHidden().frame(width: 140)
                }
                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("아직 남긴 기록이 없습니다.").font(.system(size: 12, weight: .medium))
                        Text("댓글, 질문, 평가 또는 보류를 남겨 보세요.\n기록 수는 동의한 사람 수를 뜻하지 않습니다.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    }.padding(.vertical, 12)
                } else {
                    ForEach(filtered.reversed()) { record in
                        RecordCard(record: record, model: model)
                    }
                }
            }.padding(20)
        }
        .background(Theme.paper)
    }

    @ViewBuilder
    private func composer(_ source: SourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("작성 중 · 대상 고정", systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Button("새 기록") { model.showDraftReset = true }.font(.system(size: 11))
            }
            if source.url != tab.currentURL {
                Text("다른 페이지로 이동했습니다. 이 초안은 아래 출처에 계속 연결됩니다.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text(source.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .textSelection(.enabled)
            if !source.quote.isEmpty {
                Text("“\(source.quote)”").font(.system(size: 12)).lineSpacing(4)
                    .lineLimit(7).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6)).textSelection(.enabled)
            }
            Picker("기록 종류", selection: $model.draftKind) {
                ForEach(RecordKind.allCases, id: \.self) { kind in
                    Text(label(kind)).tag(kind)
                }
            }.font(.system(size: 12))
            if model.draftKind == .evaluation {
                Picker("평가 기준", selection: $model.criterion) {
                    Text("도움 정도").tag("도움 정도")
                    Text("근거 충분성").tag("근거 충분성")
                    Text("내 조건에 적용").tag("내 조건에 적용")
                }
                Picker("나의 평가", selection: $model.evaluation) {
                    Text("긍정").tag("긍정")
                    Text("판단 어려움").tag("판단 어려움")
                    Text("부정").tag("부정")
                }
                Text("이 평가는 내 의견입니다. 사실 인증이나 다른 사람의 동의가 아닙니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.draftKind == .decision {
                Picker("이번 판단", selection: $model.disposition) {
                    ForEach(["결정", "보류", "불일치 보존", "중단"], id: \.self) { Text($0).tag($0) }
                }
                Text("이유를 아직 모르겠다면 비워 두어도 됩니다. 내 상태만 기록합니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.draftKind == .relation {
                Picker("연결 의미", selection: $model.relation) {
                    ForEach(["근거로 연결", "반례로 연결", "전제에 질문", "다른 조건의 경험", "추가 확인 필요"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Text(model.targetID == nil ? "아래 기록의 ‘연결’로 대상을 먼저 선택하세요." : "선택한 기록의 정확한 버전에 연결됩니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let id = model.targetID {
                Text("대상 기록 \(id.prefix(16))…")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if let target = model.records.first(where: { $0.id == id }) {
                    Text("\(label(target.kind)): \(target.text.isEmpty ? target.payload.disposition : target.text)")
                        .font(.system(size: 11)).lineLimit(4)
                }
            }
            ZStack(alignment: .topLeading) {
                if model.draftText.isEmpty {
                    Text(model.draftKind == .decision || model.draftKind == .evaluation
                         ? "이유 또는 남겨 둘 생각 (선택)" : "당신의 생각을 적어 주세요")
                        .font(.system(size: 12)).foregroundStyle(.tertiary).padding(8)
                }
                TextEditor(text: $model.draftText)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(3).frame(height: 100).accessibilityLabel("의견 입력")
            }
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.2)))
            Text("\(model.draftText.count) / 4,000자").font(.system(size: 9)).foregroundStyle(.secondary)
            Button(action: model.prepareReview) {
                Label("내용 확인 후 저장", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            .disabled(!model.storageReady || model.draftText.count > 4000)
        }
    }
}

struct RecordCard: View {
    let record: SignedRecord
    @ObservedObject var model: AppModel
    @State private var confirmWithdraw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label(record.kind)).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.08)).clipShape(Capsule())
                Spacer()
                Label("기기 서명", systemImage: "signature").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if model.showAllRecords {
                Text(record.source.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
            }
            if !record.source.quote.isEmpty {
                Text(record.source.quote).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            if record.kind == .evaluation {
                Text("\(record.payload.evaluationCriterion) · \(record.payload.evaluationValue)")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            if !record.payload.disposition.isEmpty {
                Text(record.payload.disposition).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            if !record.payload.relationKind.isEmpty {
                Text(record.payload.relationKind).font(.system(size: 12, weight: .semibold))
            }
            if let target = record.relationTargetID {
                Text("연결 대상 \(target.prefix(16))…").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !record.text.isEmpty {
                Text(record.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
            } else { Text("이유를 남기지 않았습니다.").font(.system(size: 11)).foregroundStyle(.secondary) }
            Text("작성 주체 \(record.actorID.prefix(12))…")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("답변") { model.target(record, kind: .answer) }
                Button("평가") { model.target(record, kind: .evaluation) }
                Button("연결") { model.target(record, kind: .relation) }
                Spacer()
                Button("철회") { confirmWithdraw = true }.foregroundStyle(.secondary)
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("이 기록의 승인을 철회할까요? 원기록과 철회 이력은 남습니다.",
                            isPresented: $confirmWithdraw) {
            Button("승인 철회", role: .destructive) { model.withdraw(record) }
            Button("취소", role: .cancel) {}
        }
    }
}

struct ReviewSheet: View {
    let item: ReviewItem
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("내가 남길 기록 확인", systemImage: "checkmark.seal")
                .font(.system(size: 23, weight: .semibold))
            Text("아래 내용과 출처를 확인한 뒤 저장해 주세요. 창을 닫거나 취소하면 저장하지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(label(item.draft.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(item.draft.source.title).font(.system(size: 15, weight: .semibold))
                    Text(item.draft.source.url).font(.system(size: 11)).textSelection(.enabled)
                    if !item.draft.source.quote.isEmpty {
                        Text("“\(item.draft.source.quote)”").font(.system(size: 13)).lineSpacing(4)
                    }
                    Divider()
                    if let criterion = item.draft.evaluationCriterion, let value = item.draft.evaluationValue {
                        Text("\(criterion): \(value)").font(.system(size: 14, weight: .semibold))
                    }
                    if let state = item.draft.disposition { Text("나의 상태: \(state)").font(.system(size: 14, weight: .semibold)) }
                    if let relation = item.draft.relationKind { Text("연결 의미: \(relation)") }
                    if let target = item.draft.relationTargetID {
                        Text("연결할 기록: \(target)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        if let targetRecord = item.targetRecord {
                            Text("대상 \(label(targetRecord.kind)) · \(targetRecord.source.title)")
                                .font(.system(size: 12, weight: .semibold))
                            Text(targetRecord.text.isEmpty ? targetRecord.payload.disposition : targetRecord.text)
                                .font(.system(size: 13)).textSelection(.enabled)
                            Text("작성 주체: \(targetRecord.actorID)").font(.system(size: 10, design: .monospaced))
                            Divider()
                        } else {
                            Text("대상 기록의 본문을 현재 저장소에서 찾지 못했습니다.").foregroundStyle(.secondary)
                        }
                    }
                    Text(item.draft.text.isEmpty ? "이유 미작성" : item.draft.text)
                        .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 380).background(Theme.paper).clipShape(RoundedRectangle(cornerRadius: 10))
            Label("저장 범위: 이 기기 · 외부 공개와 AI 전송 없음", systemImage: "laptopcomputer")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            Text("서명은 이 키로 작성했다는 기록입니다. 고유한 인간 또는 내용의 진실을 보증하지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("계속 수정") { model.review = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("확인하고 로컬 저장") { model.saveReviewed(item) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(28).frame(width: 560)
    }
}

func label(_ kind: RecordKind) -> String {
    switch kind {
    case .comment: return "댓글"
    case .question: return "질문"
    case .answer: return "답변"
    case .evaluation: return "평가"
    case .relation: return "연결"
    case .decision: return "판단 정리"
    }
}
