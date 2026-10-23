import AppKit
import Combine
import Foundation
import WebKit

struct CapturedPage {
    let url: String
    let title: String
    let quote: String
    let capturedAt: Date
}

enum PageCaptureError: LocalizedError {
    case pageNotReady
    case navigationChanged
    case noSelection
    case selectionTooLong
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .pageNotReady: return "페이지가 완전히 열린 뒤 문장을 선택해 주세요."
        case .navigationChanged: return "페이지가 바뀌었습니다. 현재 페이지에서 다시 선택해 주세요."
        case .noSelection: return "본문에서 가져올 문장을 먼저 선택해 주세요."
        case .selectionTooLong: return "선택한 문장이 너무 깁니다. 최대 8,000자 범위에서 다시 선택해 주세요."
        case .invalidResult: return "선택한 문장을 가져오지 못했습니다. 다시 선택해 주세요."
        }
    }
}

/// Remote content never receives a native message handler, filesystem API, or signing key.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView

    @Published private(set) var currentURL = ""
    @Published private(set) var title = "새 탭"
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var errorMessage: String?

    // Tabs share a temporary session; cookies and website storage are not persisted.
    private static let sessionStore = WKWebsiteDataStore.nonPersistent()
    private let onOpenTab: ((URL) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var navigationGeneration: UInt64 = 0
    private var navigationPending = false
    private var hasCommittedPage = false
    private var registeredFixturePaths: Set<String> = []
    private var requestedFixturePath: String?

    init(onOpenTab: ((URL) -> Void)? = nil) {
        self.onOpenTab = onOpenTab
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.sessionStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.tabFocusesLinks = true
        configuration.userContentController = WKUserContentController()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observeWebView()
    }

    func navigate(_ input: String) {
        do {
            let url = try Self.resolveInput(input)
            beginNativeNavigation()
            requestedFixturePath = nil
            webView.load(URLRequest(url: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only native UI calls this method with its bundled, self-contained fixture.
    /// Read permission is restricted to that file, not its containing directory.
    func loadFixture(_ url: URL) {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.isFileURL,
              ["html", "htm"].contains(file.pathExtension.lowercased()),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            errorMessage = "읽을 수 있는 HTML 예제 파일이 아닙니다."
            return
        }
        registeredFixturePaths.insert(file.path)
        requestedFixturePath = file.path
        beginNativeNavigation()
        webView.loadFileURL(file, allowingReadAccessTo: file)
    }

    func goBack() {
        guard let item = webView.backForwardList.backItem else { return }
        prepareHistoryNavigation(to: item.url)
        webView.goBack()
    }

    func goForward() {
        guard let item = webView.backForwardList.forwardItem else { return }
        prepareHistoryNavigation(to: item.url)
        webView.goForward()
    }

    func reload() {
        guard let url = webView.url else { return }
        prepareHistoryNavigation(to: url)
        webView.reload()
    }

    func stop() {
        navigationGeneration &+= 1
        navigationPending = false
        requestedFixturePath = nil
        webView.stopLoading()
        refreshState()
    }

    /// Called only from native UI, never by a page script. Whole-page opinions
    /// validate the same navigation snapshot without reading any selected text.
    func captureSelection(requireSelection: Bool = true) async throws -> CapturedPage {
        refreshState()
        guard hasCommittedPage, !navigationPending, !webView.isLoading,
              let sourceURL = webView.url, captureURLAllowed(sourceURL) else {
            throw PageCaptureError.pageNotReady
        }
        let generation = navigationGeneration
        let observedURL = sourceURL.absoluteString
        let selectionScript = """
        (() => {
            const selection = window.getSelection();
            const text = selection ? String(selection) : "";
            return text.length > 8000
                ? { tooLong: true, text: "" }
                : { tooLong: false, text };
        })()
        """
        let script = requireSelection ? selectionScript : "({ tooLong: false, text: \"\" })"
        // A separate JS world avoids page-defined globals/prototypes. The DOM text
        // remains untrusted data and is never evaluated or treated as an instruction.
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                continuation.resume(with: result)
            }
        }
        refreshState()
        guard generation == navigationGeneration,
              webView.url?.absoluteString == observedURL,
              !navigationPending, !webView.isLoading else {
            throw PageCaptureError.navigationChanged
        }
        guard let payload = result as? [String: Any],
              let tooLong = payload["tooLong"] as? Bool,
              let text = payload["text"] as? String else { throw PageCaptureError.invalidResult }
        guard !tooLong, text.utf16.count <= 8_000 else { throw PageCaptureError.selectionTooLong }
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requireSelection || !quote.isEmpty else { throw PageCaptureError.noSelection }
        return CapturedPage(url: observedURL, title: title, quote: quote, capturedAt: Date())
    }

    // MARK: - Input and observed state

    static func resolveInput(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192 else {
            throw InputError.invalid
        }
        let containsWhitespace = value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        if !containsWhitespace,
           value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return try validatedWebURL(value)
        }
        let authority = String(value.prefix { !"/?#".contains($0) })
        let hostCandidate = authority.lowercased()
        let loopback = hostCandidate == "localhost" || hostCandidate.hasPrefix("localhost:")
            || hostCandidate == "[::1]" || hostCandidate.hasPrefix("[::1]:")
            || hostCandidate == "127.0.0.1" || hostCandidate.hasPrefix("127.0.0.1:")
        // Treat localhost:port as an address before looking for URI schemes.
        if !containsWhitespace, loopback {
            return try validatedWebURL("http://" + value)
        }
        if value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            throw InputError.unsupportedScheme
        }
        if !containsWhitespace, authority.contains("."), !authority.contains("@") {
            return try validatedWebURL("https://" + value)
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        guard let result = components.url else { throw InputError.invalid }
        return result
    }

    private static func validatedWebURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), isWebURL(url),
              url.user == nil, url.password == nil else { throw InputError.invalid }
        return url
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host?.isEmpty ?? true)
    }

    private enum InputError: LocalizedError {
        case invalid, unsupportedScheme
        var errorDescription: String? {
            switch self {
            case .invalid: return "올바른 웹 주소나 검색어를 입력해 주세요."
            case .unsupportedScheme: return "주소창에서는 http 또는 https 웹 주소만 열 수 있습니다."
            }
        }
    }

    private func observeWebView() {
        observations.append(webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.navigationGeneration &+= 1
                self.refreshState()
                // Fragment/history updates need not start a document load.
                if !self.webView.isLoading { self.navigationPending = false }
            }
        })
        observations.append(webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
    }

    private func refreshState() {
        let observedURL = webView.url?.absoluteString ?? ""
        if currentURL != observedURL { navigationGeneration &+= 1; currentURL = observedURL }
        let observedTitle = String((webView.title ?? "").prefix(512))
        title = observedTitle.isEmpty ? (webView.url?.host ?? "새 탭") : observedTitle
        isLoading = webView.isLoading
        estimatedProgress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func beginNativeNavigation() {
        navigationGeneration &+= 1
        navigationPending = true
        errorMessage = nil
    }

    private func prepareHistoryNavigation(to url: URL) {
        requestedFixturePath = registeredFixturePath(url)
        beginNativeNavigation()
    }

    private func registeredFixturePath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return registeredFixturePaths.contains(path) ? path : nil
    }

    private func captureURLAllowed(_ url: URL) -> Bool {
        Self.isWebURL(url) || registeredFixturePath(url) != nil
    }

    private func routeNewTab(_ url: URL) {
        guard Self.isWebURL(url) else {
            errorMessage = "이 링크의 주소 형식은 열 수 없습니다."
            return
        }
        if let onOpenTab { onOpenTab(url) } else { navigate(url.absoluteString) }
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            errorMessage = "이 초기 버전에서는 파일 다운로드를 제공하지 않습니다."
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            routeNewTab(url)
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        var allowed = Self.isWebURL(url)
        if let path = registeredFixturePath(url) {
            let sourcePath = navigationAction.sourceFrame.request.url.flatMap(registeredFixturePath)
            allowed = (isMainFrame && requestedFixturePath == path) || sourcePath == path
            if isMainFrame, requestedFixturePath == path { requestedFixturePath = nil }
        } else if url.absoluteString == "about:blank" {
            // Allow only internal/child blank frames; never open this from the address bar.
            allowed = !isMainFrame || webView.url == nil
        }
        guard allowed else {
            if isMainFrame {
                navigationPending = false
                errorMessage = "이 주소 형식은 차단했습니다. 웹 주소로 이동해 주세요."
            }
            decisionHandler(.cancel)
            return
        }
        if isMainFrame {
            navigationGeneration &+= 1
            navigationPending = true
            errorMessage = nil
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        guard navigationResponse.canShowMIMEType, !attachment else {
            navigationPending = false
            errorMessage = "이 초기 버전에서는 파일 다운로드를 제공하지 않습니다."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration &+= 1
        navigationPending = true
        // A failed provisional load must not label the old DOM with the new URL.
        hasCommittedPage = false
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommittedPage = true
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationPending = false
        requestedFixturePath = nil
        hasCommittedPage = true
        refreshState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        navigationPending = false
        requestedFixturePath = nil
        let nsError = error as NSError
        if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
            errorMessage = error.localizedDescription
        }
        refreshState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationGeneration &+= 1
        navigationPending = false
        hasCommittedPage = false
        errorMessage = "웹페이지 프로세스가 종료되었습니다. 새로고침해 주세요."
        refreshState()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Never override certificate trust or supply app credentials to a website.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            errorMessage = "별도의 서버 인증이 필요한 페이지는 이 버전에서 지원하지 않습니다."
        }
    }

    func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge,
                 shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void) {
        decisionHandler(false)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel(nil)
        errorMessage = "파일 다운로드를 취소했습니다."
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel(nil)
        errorMessage = "파일 다운로드를 취소했습니다."
    }

    // MARK: - Page requests cannot invoke native capabilities

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { routeNewTab(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
        errorMessage = "이 버전에서는 웹페이지의 카메라·마이크 접근을 허용하지 않습니다."
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
        errorMessage = "이 버전에서는 웹페이지에 로컬 파일을 전달하지 않습니다."
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        // Untrusted pages cannot display a native-looking approval dialogue.
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}
