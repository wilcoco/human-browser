package org.humanbrowser.android;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.net.http.SslError;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.webkit.*;
import android.widget.*;
import android.text.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;

/** Native approval UI is separate from untrusted web content. No JavaScript bridge. */
public final class MainActivity extends Activity {
    static final String DEMO = "https://human-browser.invalid/demo";
    static final int PAPER = 0xfff6f5ef, INK = 0xff203e32, GREEN = 0xff286951, MUTED = 0xff687b71;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private WebView web;
    private EditText address;
    private TextView status, panelTitle;
    private LinearLayout root, recordsBox, panel;
    private ScrollView recordsScroll;
    private ProgressBar progress;
    private RecordStore store;
    private PublicApi publicApi;
    private volatile boolean publicMode;
    private boolean publicBusy;
    private volatile long publicGeneration;
    private final java.util.concurrent.ExecutorService network = java.util.concurrent.Executors.newSingleThreadExecutor();
    private JSONObject draft;
    private String draftToken = UUID.randomUUID().toString(), currentUrl = "", failedUrl = "";
    private long navigationGeneration = 0;
    private boolean pageReady, capturing, expanded, allRecords;
    private AlertDialog editor;
    private final String[] kinds = {"comment", "question", "answer", "evaluation", "relation", "decision"};
    private final String[] labels = {"댓글", "질문", "답변", "평가", "연결", "판단 정리"};
    private final Runnable observe = new Runnable() {
        public void run() { syncUrl(); handler.postDelayed(this, 600); }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        try { store = new RecordStore(this); store.getWritableDatabase(); }
        catch (Exception e) { toast("저장소를 열지 못했습니다. " + e.getMessage()); }
        try {
            String saved = getPreferences(MODE_PRIVATE).getString("draft", "");
            if (!saved.isEmpty()) draft = new JSONObject(saved);
        } catch (Exception e) { toast("보관한 초안을 읽지 못했습니다. 원본은 앱 저장소에 남아 있습니다."); }
        publicApi = new PublicApi(this);
        buildUI(); configureWeb();
        String shared = getIntent().getStringExtra(Intent.EXTRA_TEXT);
        if (Intent.ACTION_SEND.equals(getIntent().getAction()) && shared != null) openSharedUrl(shared);
        else web.loadUrl(DEMO);
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent);
        String shared = intent.getStringExtra(Intent.EXTRA_TEXT);
        if (Intent.ACTION_SEND.equals(intent.getAction()) && shared != null) openSharedUrl(shared);
    }

    private void openSharedUrl(String shared) {
        java.util.regex.Matcher match = java.util.regex.Pattern.compile("https://[^\\s<>]+").matcher(shared);
        if (match.find() && isWebUrl(match.group())) navigate(match.group());
        else { toast("공유된 내용에서 HTTPS 주소를 찾지 못했습니다."); if(currentUrl.isEmpty()) web.loadUrl(DEMO); }
    }

    private void buildUI() {
        root = vertical(); root.setBackgroundColor(PAPER);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                         insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(root);
        LinearLayout heading = row(); heading.setPadding(dp(15), dp(6), dp(8), dp(2));
        TextView brand = text("사람 브라우저", 19, INK); brand.setTypeface(null, Typeface.BOLD);
        heading.addView(brand, new LinearLayout.LayoutParams(0, dp(44), 1));
        heading.addView(button("메뉴", v -> showMenu(v)));
        root.addView(heading);
        LinearLayout nav = row(); nav.setPadding(dp(6), 0, dp(6), 0);
        nav.addView(button("‹", v -> { if (web.canGoBack()) web.goBack(); }));
        address = new EditText(this); address.setSingleLine(true); address.setTextSize(14);
        address.setHint("웹 주소 또는 검색어"); address.setContentDescription("주소 또는 검색어");
        address.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        address.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_GO);
        address.setOnEditorActionListener((v, action, event) -> { navigate(address.getText().toString()); return true; });
        nav.addView(address, new LinearLayout.LayoutParams(0, dp(48), 1));
        nav.addView(button("이동", v -> navigate(address.getText().toString())));
        root.addView(nav);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100); root.addView(progress, new LinearLayout.LayoutParams(-1, dp(2)));
        web = new WebView(this); root.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
        status = text("이 기기에서 직접 탐색 · 기록은 로컬 보관", 11, MUTED);
        status.setPadding(dp(12), dp(3), dp(12), dp(3)); root.addView(status);
        LinearLayout actions = row(); actions.setPadding(dp(4), 0, dp(4), 0);
        addAction(actions, "댓글·판단", v -> togglePanel());
        addAction(actions, "페이지 기록", v -> beginDraft(false));
        addAction(actions, "선택 인용", v -> beginDraft(true)); root.addView(actions);
        panel = vertical(); panel.setPadding(dp(12), 0, dp(12), dp(6)); panel.setVisibility(View.GONE);
        LinearLayout tools = row(); panelTitle = text("이 페이지의 기록", 14, INK);
        tools.addView(panelTitle, new LinearLayout.LayoutParams(0, dp(42), 1));
        tools.addView(button("공개/개인", v -> switchPublicMode()));
        tools.addView(button("전체/현재", v -> { if(publicMode) { refreshRecords(); } else { allRecords = !allRecords; refreshRecords(); } }));
        tools.addView(button("접기", v -> togglePanel())); panel.addView(tools);
        recordsScroll = new ScrollView(this); recordsBox = vertical(); recordsScroll.addView(recordsBox);
        panel.addView(recordsScroll, new LinearLayout.LayoutParams(-1, -1));
        root.addView(panel, new LinearLayout.LayoutParams(-1, dp(290)));
    }

    @SuppressWarnings("deprecation") private void configureWeb() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false); s.setAllowContentAccess(false);
        s.setAllowFileAccessFromFileURLs(false); s.setAllowUniversalAccessFromFileURLs(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setJavaScriptCanOpenWindowsAutomatically(false); s.setSupportMultipleWindows(true);
        s.setGeolocationEnabled(false); s.setMediaPlaybackRequiresUserGesture(true);
        s.setSafeBrowsingEnabled(true);
        WebView.setWebContentsDebuggingEnabled(false);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.removeJavascriptInterface("searchBoxJavaBridge_");
        web.removeJavascriptInterface("accessibility"); web.removeJavascriptInterface("accessibilityTraversal");
        web.setDownloadListener((url, ua, cd, mime, size) -> toast("이 알파 버전은 파일 다운로드를 지원하지 않습니다."));
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                if (!isWebUrl(req.getUrl().toString())) { if (req.isForMainFrame()) toast("HTTPS 웹 주소만 열 수 있습니다."); return true; }
                return false;
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                String u = req.getUrl().toString();
                if (DEMO.equals(u) || (DEMO + "/other").equals(u)) {
                    try { return new WebResourceResponse("text/html", "UTF-8", getAssets().open(u.endsWith("/other") ? "other.html" : "demo.html")); }
                    catch (IOException e) { return new WebResourceResponse("text/plain", "UTF-8", new ByteArrayInputStream("예제를 읽지 못했습니다.".getBytes(StandardCharsets.UTF_8))); }
                }
                return super.shouldInterceptRequest(view, req);
            }
            @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap icon) {
                navigationGeneration++; pageReady = false; failedUrl = ""; syncUrl();
            }
            @Override public void doUpdateVisitedHistory(WebView view, String url, boolean reload) { syncUrl(); }
            @Override public void onPageFinished(WebView view, String url) {
                if (url.equals(view.getUrl()) && !url.equals(failedUrl) && isWebUrl(url)) pageReady = true;
                syncUrl(); progress.setVisibility(View.GONE);
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) { pageReady = false; failedUrl = request.getUrl().toString(); status.setText("페이지를 열지 못했습니다. 주소와 연결을 확인하세요."); }
            }
            @Override public void onReceivedSslError(WebView view, SslErrorHandler h, SslError error) {
                h.cancel(); pageReady = false; failedUrl = view.getUrl(); toast("인증서 확인에 실패하여 연결을 중단했습니다.");
            }
            @Override public void onReceivedHttpAuthRequest(WebView view, HttpAuthHandler h, String host, String realm) { h.cancel(); }
            @Override public void onSafeBrowsingHit(WebView view, WebResourceRequest req, int type, SafeBrowsingResponse response) { response.backToSafety(true); }
            @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                pageReady = false; toast("웹 프로세스가 종료되었습니다. 앱을 다시 열어 주세요. 기록은 보관되어 있습니다.");
                root.removeView(view); view.destroy(); return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onProgressChanged(WebView view, int p) { progress.setProgress(p); progress.setVisibility(p < 100 ? View.VISIBLE : View.GONE); }
            @Override public void onReceivedTitle(WebView view, String title) { if (expanded) refreshRecords(); }
            @Override public void onPermissionRequest(PermissionRequest r) { r.deny(); }
            @Override public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) { callback.invoke(origin, false, false); }
            @Override public boolean onShowFileChooser(WebView view, android.webkit.ValueCallback<Uri[]> cb, FileChooserParams params) { cb.onReceiveValue(null); return true; }
            @Override public boolean onCreateWindow(WebView v, boolean dialog, boolean gesture, Message msg) {
                toast("새 창 링크는 길게 눌러 주소를 복사한 뒤 주소창에서 열 수 있습니다."); return false;
            }
            @Override public boolean onJsAlert(WebView v, String u, String m, JsResult r) { r.cancel(); return true; }
            @Override public boolean onJsConfirm(WebView v, String u, String m, JsResult r) { r.cancel(); return true; }
            @Override public boolean onJsPrompt(WebView v, String u, String m, String d, JsPromptResult r) { r.cancel(); return true; }
        });
    }

    private String shortTitle(String title) {
        return title.codePointCount(0,title.length()) > 500 ? title.substring(0,title.offsetByCodePoints(0,500)) + "…" : title;
    }
    private boolean isWebUrl(String value) {
        if (value == null || value.length() > 8192) return false;
        Uri u = Uri.parse(value);
        return "https".equalsIgnoreCase(u.getScheme()) && u.getHost() != null && u.getUserInfo() == null;
    }
    private void navigate(String input) {
        String value = input.trim(); if (value.isEmpty()) return;
        if (!value.contains(" ") && !value.contains(":") && value.contains(".")) value = "https://" + value;
        else if (!value.matches("^[A-Za-z][A-Za-z0-9+.-]*:.*")) value = "https://duckduckgo.com/?q=" + Uri.encode(value);
        if (!isWebUrl(value)) { toast("이 알파에서는 HTTPS 주소를 지원합니다."); return; }
        ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(address.getWindowToken(), 0);
        address.clearFocus(); web.requestFocus(); pageReady = false; navigationGeneration++; web.loadUrl(value);
    }
    private void syncUrl() {
        if (web == null) return;
        String next = web.getUrl(); if (next == null) next = "";
        if (!next.equals(currentUrl)) {
            navigationGeneration++; currentUrl = next;
            if (!address.hasFocus()) address.setText(next);
            status.setText(draft == null ? "이 기기에서 직접 탐색 · 기록은 로컬 보관" : "작성 중인 초안의 출처는 고정되어 있습니다");
            refreshRecords();
        }
    }
    private void beginDraft(boolean selection) {
        if (draft != null) { showEditor(); return; }
        if (!pageReady || !isWebUrl(web.getUrl())) { toast("페이지가 열린 뒤 기록해 주세요."); return; }
        if (capturing) return;
        syncUrl(); final long generation = navigationGeneration;
        final String url = currentUrl, token = draftToken, title = web.getTitle() == null ? url : web.getTitle();
        if (!selection) { acceptCapture(url, title, "", token, generation); return; }
        capturing = true;
        // Pull untrusted text on an explicit native action. No callable native bridge exists.
        web.evaluateJavascript("(function(){var s=window.getSelection();var t=s?String(s):'';return t.length>8000?'__HB_TOO_LONG__':t;})()", result -> {
            capturing = false; syncUrl();
            if (generation != navigationGeneration || !token.equals(draftToken) || !url.equals(web.getUrl()) || !pageReady || draft != null) { toast("페이지 또는 초안이 바뀌었습니다. 다시 선택해 주세요."); return; }
            try {
                Object decoded = new JSONTokener(result).nextValue();
                if (!(decoded instanceof String)) throw new Exception("문장 선택 실패");
                String quote = ((String)decoded).trim();
                if (quote.equals("__HB_TOO_LONG__") || quote.length() > 8000) { toast("선택한 문장은 8,000자 이내여야 합니다."); return; }
                if (quote.isEmpty()) { toast("본문을 길게 눌러 문장을 선택한 뒤 ‘선택 인용’을 누르세요."); return; }
                acceptCapture(url, title, quote, token, generation);
            } catch (Exception e) { toast("선택 문장을 가져오지 못했습니다."); }
        });
    }
    private void acceptCapture(String url, String title, String quote, String token, long generation) {
        if (!token.equals(draftToken) || draft != null || generation != navigationGeneration) return;
        draft = new JSONObject(); put(draft,"url",url); put(draft,"title",shortTitle(title)); put(draft,"quote",quote);
        put(draft,"capturedAt",Instant.now().toString()); put(draft,"kind","comment"); put(draft,"text","");
        put(draft,"criterion","도움 정도"); put(draft,"value","판단 어려움"); put(draft,"disposition","보류");
        put(draft,"relation","근거로 연결"); put(draft,"targetId",""); persistDraft(); showEditor();
    }
    private void showEditor() {
        if (draft == null || (editor != null && editor.isShowing())) return;
        LinearLayout content = vertical(); content.setPadding(dp(20), dp(8), dp(20), dp(12));
        content.addView(text("출처 고정 · 미승인 초안", 12, GREEN));
        content.addView(text(draft.optString("title"), 18, INK));
        content.addView(text(draft.optString("url"), 11, MUTED));
        if (!draft.optString("quote").isEmpty()) content.addView(text("“" + draft.optString("quote") + "”",14, INK));
        if (!draft.optString("targetId").isEmpty()) content.addView(text("대상 기록: " + draft.optString("targetText") + "\n" + draft.optString("targetId"), 12, MUTED));
        content.addView(text("무엇을 남길까요?", 13, INK));
        Spinner kind = spinner(labels, indexOf(kinds, draft.optString("kind"))); content.addView(kind);
        LinearLayout options = vertical(); content.addView(options);
        EditText body = new EditText(this); body.setHint("당신의 생각을 적어 주세요"); body.setTextSize(16);
        body.setGravity(Gravity.TOP); body.setMinLines(3); body.setMaxLines(7);
        body.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        body.setFilters(new InputFilter[]{new InputFilter.LengthFilter(4000)}); body.setText(draft.optString("text"));
        body.setContentDescription("의견 입력"); content.addView(body);
        body.addTextChangedListener(watcher(() -> { if (draft != null) { put(draft,"text",body.getText().toString()); persistDraft(); } }));
        kind.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onNothingSelected(AdapterView<?> p) {}
            public void onItemSelected(AdapterView<?> p, View v, int pos, long id) {
                if (draft == null) return; put(draft,"kind",kinds[pos]); options.removeAllViews();
                if (pos == 3) {
                    addChoice(options,"평가 기준","criterion",new String[]{"도움 정도","근거 충분성","내 조건에 적용"});
                    addChoice(options,"나의 평가","value",new String[]{"판단 어려움","긍정","부정"});
                } else if (pos == 5) {
                    addChoice(options,"이번 판단","disposition",new String[]{"보류","결정","불일치 보존","중단"});
                    options.addView(text("이유를 아직 모르겠다면 비워 두어도 됩니다. 내 상태만 기록합니다.",12,MUTED));
                } else if (pos == 4) {
                    addChoice(options,"관계","relation",new String[]{"근거로 연결","반례로 연결","추가 확인 필요","다른 조건의 경험"});
                    if (draft.optString("targetId").isEmpty()) options.addView(text("초안을 닫고 기록 카드의 ‘연결’을 눌러 대상을 선택하세요.",12,MUTED));
                }
                body.setHint(pos == 3 || pos == 5 ? "이유 또는 생각 (선택)" : "당신의 생각을 적어 주세요"); persistDraft();
            }
        });
        content.addView(text("초안은 이 기기에 자동 보관됩니다. 확인 버튼을 누르기 전에는 승인한 기록이 아닙니다.",11,MUTED));
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.addView(content);
        editor = new AlertDialog.Builder(this).setTitle("나의 기록").setView(scroll)
            .setNegativeButton("닫고 읽기", (d,w) -> persistDraft())
            .setNeutralButton("초안 지우기", null).setPositiveButton("내용 확인", null).create();
        editor.setOnShowListener(d -> {
            editor.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> reviewDraft());
            editor.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> new AlertDialog.Builder(this)
                .setTitle("작성 중인 초안을 지울까요?").setMessage("승인해 저장한 기록은 유지됩니다.")
                .setNegativeButton("계속 작성",null).setPositiveButton("초안 지우기",(a,b) -> { clearDraft(); editor.dismiss(); }).show());
        });
        editor.show();
    }
    private void reviewDraft() {
        if (draft == null || store == null) return;
        try {
            JSONObject frozen = new JSONObject(draft.toString()); String kind = frozen.optString("kind");
            if (!kind.equals("decision") && !kind.equals("evaluation") && frozen.optString("text").trim().isEmpty()) { toast("기록할 내용을 입력해 주세요."); return; }
            if (kind.equals("relation") && frozen.optString("targetId").isEmpty()) { toast("기록 카드의 ‘연결’에서 대상을 선택해 주세요."); return; }
            if (!Arrays.asList("answer","evaluation","relation").contains(kind)) put(frozen,"targetId","");
            final String token = draftToken;
            String summary = label(kind) + "\n\n" + frozen.optString("title") + "\n" + frozen.optString("url") + "\n\n";
            if (!frozen.optString("quote").isEmpty()) summary += "선택 문장\n“" + frozen.optString("quote") + "”\n\n";
            if (!frozen.optString("targetId").isEmpty()) summary += "대상 기록\n" + frozen.optString("targetText") + "\n" + frozen.optString("targetId") + "\n\n";
            if (kind.equals("evaluation")) summary += frozen.optString("criterion") + ": " + frozen.optString("value") + "\n\n";
            if (kind.equals("decision")) summary += "나의 상태: " + frozen.optString("disposition") + "\n\n";
            if (kind.equals("relation")) summary += "관계: " + frozen.optString("relation") + "\n\n";
            summary += frozen.optString("text").isEmpty() ? "이유 미작성" : frozen.optString("text");
            summary += "\n\n저장 범위: 이 기기\n다른 사람이나 AI에게 보내지 않습니다.\n서명은 키의 행위를 확인하며, 인간의 고유성이나 진실을 보증하지 않습니다.";
            TextView detail = text(summary,14,INK); detail.setTextIsSelectable(true); detail.setPadding(dp(22),dp(8),dp(22),dp(8));
            ScrollView scroll = new ScrollView(this); scroll.addView(detail);
            AlertDialog confirm = new AlertDialog.Builder(this).setTitle("내가 남길 기록 확인").setView(scroll)
                .setNegativeButton("계속 수정",null).setPositiveButton("확인하고 저장",null).create();
            confirm.setOnShowListener(d -> confirm.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                if (!token.equals(draftToken)) { confirm.dismiss(); toast("초안이 바뀌었습니다. 다시 확인해 주세요."); return; }
                try { store.commit(recordPayload(frozen)); clearDraft(); publicMode=false; confirm.dismiss(); if (editor != null) editor.dismiss();
                      if (!expanded) togglePanel(); refreshRecords(); toast("이 기기에 저장했습니다."); }
                catch (Exception e) { toast("저장 실패: " + e.getMessage()); }
            })); confirm.show();
        } catch (Exception e) { toast("확인 화면을 만들지 못했습니다."); }
    }
    private JSONObject recordPayload(JSONObject input) throws JSONException {
        JSONObject value = new JSONObject(input.toString());
        value.remove("targetText");
        String kind = value.optString("kind");
        if (!kind.equals("evaluation")) { value.remove("criterion"); value.remove("value"); }
        if (!kind.equals("decision")) value.remove("disposition");
        if (!kind.equals("relation")) value.remove("relation");
        if (!Arrays.asList("answer","evaluation","relation").contains(kind)) value.remove("targetId");
        return value;
    }
    private void targetRecord(JSONObject record, String kind) {
        if (draft != null && !kind.equals("relation")) { toast("작성 중인 초안을 먼저 정리해 주세요."); showEditor(); return; }
        try {
            if (draft == null) {
                draft = new JSONObject(); for (String k : new String[]{"url","title","quote","capturedAt"}) put(draft,k,record.optString(k));
                put(draft,"text",""); put(draft,"criterion","도움 정도"); put(draft,"value","판단 어려움");
                put(draft,"disposition","보류"); put(draft,"relation","근거로 연결");
            }
            draftToken = UUID.randomUUID().toString(); put(draft,"kind",kind); put(draft,"targetId",record.getString("id"));
            put(draft,"targetText",label(record.optString("kind")) + " · " + record.optString("text") + " " + record.optString("disposition"));
            persistDraft(); showEditor();
        } catch (Exception e) { toast("대상을 선택하지 못했습니다."); }
    }
    private void refreshRecords() {
        if (recordsBox == null || store == null) return;
        publicGeneration++;
        if(publicMode) { loadPublic(0,false); return; }
        recordsBox.removeAllViews(); panelTitle.setText(allRecords ? "전체 로컬 기록" : "이 페이지의 기록");
        if (draft != null) recordsBox.addView(button("작성 중인 초안 이어쓰기",v -> showEditor()));
        try {
            JSONArray records = store.list(currentUrl,allRecords);
            if (records.length() == 0) recordsBox.addView(text("아직 기록이 없습니다.\n읽고, 질문하고, 판단을 남겨 보세요.",15,MUTED));
            for (int i=0; i<records.length(); i++) {
                JSONObject record = records.getJSONObject(i); LinearLayout card = vertical();
                card.setPadding(dp(12),dp(12),dp(12),dp(8)); card.setBackground(round(Color.WHITE));
                LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(-1,-2); cp.bottomMargin = dp(9); recordsBox.addView(card,cp);
                card.addView(text(label(record.optString("kind")) + " · 기기 키 서명",12,GREEN));
                if (allRecords) card.addView(text(record.optString("title"),13,MUTED));
                if (!record.optString("quote").isEmpty()) { TextView q=text("“"+record.optString("quote")+"”",12,MUTED); q.setMaxLines(3); card.addView(q); }
                if (record.optString("kind").equals("evaluation")) card.addView(text(record.optString("criterion")+" · "+record.optString("value"),14,GREEN));
                if (record.optString("kind").equals("decision")) card.addView(text(record.optString("disposition"),16,GREEN));
                if (record.optString("kind").equals("relation")) card.addView(text(record.optString("relation"),14,GREEN));
                TextView body=text(record.optString("text").isEmpty()?"이유 미작성":record.optString("text"),15,INK); body.setTextIsSelectable(true); card.addView(body);
                if (!record.optString("targetId").isEmpty()) card.addView(text("대상 기록: "+record.optString("targetId"),10,MUTED));
                LinearLayout links=row(); addAction(links,"답변",v -> targetRecord(record,"answer")); addAction(links,"평가",v -> targetRecord(record,"evaluation")); addAction(links,"연결",v -> targetRecord(record,"relation"));
                addAction(links,"철회",v -> new AlertDialog.Builder(this).setTitle("승인을 철회할까요?")
                    .setMessage("원기록과 철회 이력은 보존됩니다. 공개한 기록이면 서버에도 철회를 요청합니다. 전송 실패 시 메뉴의 공개 요청 재전송을 이용하세요.").setNegativeButton("취소",null)
                    .setPositiveButton("철회",(d,w) -> { try { withdrawRecord(record); refreshRecords(); } catch(Exception e){ toast(e.getMessage()); } }).show()); card.addView(links);
                card.addView(button(publicApi.wasPublishedOrQueued(record.optString("id")) ? "공개 요청됨 · 재전송" : "이 기록 공개하기",v -> confirmPublish(record)));
            }
        } catch(Exception e) { recordsBox.addView(text("기록을 읽지 못했습니다: "+e.getMessage(),13,MUTED)); }
    }
    private void switchPublicMode() {
        if(publicMode) { publicMode=false; refreshRecords(); return; }
        new AlertDialog.Builder(this).setTitle("공개 댓글 보기")
            .setMessage("공개 보기 중 이 페이지와 이후 이동한 페이지의 주소를 사람 브라우저 서버에 보내 댓글을 조회합니다. 개인 기록·초안·웹페이지 본문은 전송하지 않습니다. ‘공개/개인’을 다시 누르면 개인 모드로 돌아갑니다.")
            .setNegativeButton("취소",null).setPositiveButton("공개 보기",(d,w)->{publicMode=true;refreshRecords();}).show();
    }
    private void confirmPublish(JSONObject record) {
        String detail=record.optString("url")+"\n\n"+record.optString("quote")+"\n\n"+record.optString("text")+"\n"+record.optString("criterion")+" "+record.optString("value")+" "+record.optString("disposition")+"\n\n대상: "+record.optString("targetId")+"\n\n이 기록의 출처·인용·의견·기기 공개키가 서버에 저장되고 누구나 볼 수 있습니다. 철회해도 서버 이력과 전달된 사본은 남습니다. 다른 개인 기록은 전송하지 않습니다.";
        TextView detailView=text(detail,14,INK);detailView.setPadding(dp(20),dp(8),dp(20),dp(8));ScrollView scroll=new ScrollView(this);scroll.addView(detailView);
        new AlertDialog.Builder(this).setTitle("이 기록을 공개할까요?").setView(scroll).setNegativeButton("취소",null)
            .setPositiveButton("확인하고 공개",(d,w)->{try{publicApi.enqueue(record);flushPublic();}catch(Exception e){toast(e.getMessage());}}).show();
    }
    private void withdrawRecord(JSONObject record) throws Exception {
        String id=record.getString("id"); boolean shared=publicApi.wasPublishedOrQueued(id);
        store.withdraw(id);
        if(shared){publicApi.enqueue(store.withdrawalFor(id));flushPublic();}
    }
    private void flushPublic() {
        if(publicBusy){toast("서버 전송 중입니다.");return;}
        try {
            JSONArray history=new JSONObject(store.exportJSON()).getJSONArray("records");
            for(int i=0;i<history.length();i++) { JSONObject r=history.getJSONObject(i);
                if("withdrawal".equals(r.optString("operation")) && publicApi.wasPublishedOrQueued(r.optString("withdrawnRecordId")) && !publicApi.wasPublishedOrQueued(r.optString("id"))) publicApi.enqueue(r);
            }
        }catch(Exception e){toast("철회 요청 확인 실패: "+e.getMessage());return;}
        publicBusy=true;toast("공개 요청을 전송합니다.");
        network.execute(()->{String message;
            try{publicApi.flush();message="공개 요청이 서버에 반영되었습니다.";}catch(Exception e){message="전송 보류: "+e.getMessage()+" · 메뉴에서 재전송할 수 있습니다.";}
            final String result=message;handler.post(()->{publicBusy=false;if(!isDestroyed()){toast(result);refreshRecords();}});
        });
    }
    private void loadPublic(long before,boolean append) {
        final long generation=publicGeneration;final String source=currentUrl;
        if(!append)recordsBox.removeAllViews();panelTitle.setText("이 페이지의 공개 기록");
        TextView loading=text("서버에서 불러오는 중…",12,MUTED);recordsBox.addView(loading);
        network.execute(()->{if(!publicMode || generation!=publicGeneration)return; JSONObject result=null;String error=null;
            try{result=publicApi.page(source,before);}catch(Exception e){error=e.getMessage();}
            final JSONObject page=result;final String failure=error;
            handler.post(()->{
                if(isDestroyed()||!publicMode||generation!=publicGeneration||!source.equals(currentUrl))return;
                recordsBox.removeView(loading);
                if(failure!=null){recordsBox.addView(text("불러오기 실패: "+failure,13,MUTED));recordsBox.addView(button("다시 불러오기",v->refreshRecords()));return;}
                JSONArray records=page.optJSONArray("records");
                if(records.length()==0&&!append)recordsBox.addView(text("공개된 기록이 없습니다. 개인 기록의 ‘공개하기’로 참여하세요.",14,MUTED));
                for(int i=0;i<records.length();i++)renderPublicCard(records.optJSONObject(i));
                long next=page.optLong("nextBefore",0);
                if(next>0){Button more=button("이전 기록 더 보기",null);more.setOnClickListener(v->{recordsBox.removeView(more);loadPublic(next,true);});recordsBox.addView(more);}
            });
        });
    }
    private void renderPublicCard(JSONObject r) {
        LinearLayout card=vertical();card.setPadding(dp(12),dp(8),dp(12),dp(8));card.setBackground(round(Color.WHITE));recordsBox.addView(card);
        card.addView(text(label(r.optString("kind"))+" · 공개 기록",13,GREEN));
        TextView actor=text(r.optString("actorId"),10,MUTED);actor.setTextIsSelectable(true);card.addView(actor);
        if(!r.optString("quote").isEmpty())card.addView(text("“"+r.optString("quote")+"”",12,MUTED));
        card.addView(text(r.optString("text")+"\n"+r.optString("criterion")+" "+r.optString("value")+" "+r.optString("disposition"),15,INK));
        if(!r.optString("targetId").isEmpty())card.addView(text("대상: "+r.optString("targetId"),10,MUTED));
        LinearLayout actions=row();addAction(actions,"답변",v->targetRecord(r,"answer"));addAction(actions,"평가",v->targetRecord(r,"evaluation"));addAction(actions,"연결",v->targetRecord(r,"relation"));card.addView(actions);
    }
    private void togglePanel() { expanded=!expanded; panel.setVisibility(expanded?View.VISIBLE:View.GONE); if(expanded) refreshRecords(); }
    private void showMenu(View anchor) {
        PopupMenu menu=new PopupMenu(this,anchor);
        String[] actions={"사용 연습 페이지","새로고침","초안 이어쓰기","기록 내보내기","앱 정보","공개 요청 재전송"};
        for(int i=0;i<actions.length;i++) menu.getMenu().add(0,i,i,actions[i]);
        menu.setOnMenuItemClickListener(item -> {
            switch(item.getItemId()) {
                case 0: navigate(DEMO); break;
                case 1: pageReady=false; web.reload(); break;
                case 2: if(draft!=null) showEditor(); else toast("작성 중인 초안이 없습니다."); break;
                case 3: exportRecords(); break;
                case 4: new AlertDialog.Builder(this).setTitle("사람 브라우저 · 0.2.0 알파")
                    .setMessage("웹페이지는 휴대폰에서 직접 엽니다. 개인 기록과 초안은 앱 내부에 보관합니다. 공개하기를 확인한 기록만 Railway 서버에 전송합니다.\n\n공개/개인 버튼에서 다른 사람의 공개 기록을 볼 수 있습니다. 공개 보기 중에는 페이지 주소가 서버로 전달됩니다. AI와 분산망은 아직 없습니다. HTTPS 페이지를 지원합니다.\n\n웹사이트는 접속 주소와 일반적인 웹 요청을 받습니다. 공개한 기록은 다른 사람이 열람·복사할 수 있습니다. 철회하면 공개 목록에서 숨겨지며 서버 이력과 이미 전달된 사본은 남습니다. 앱 삭제 시 로컬 기록과 서명 키가 삭제됩니다.\n\nMac 개발판과 기록 파일 형식은 아직 호환되지 않습니다.")
                    .setPositiveButton("확인",null).show(); break;
                case 5: flushPublic(); break;
            } return true;
        }); menu.show();
    }
    private void exportRecords() {
        if(store==null) return;
        new AlertDialog.Builder(this).setTitle("기록을 파일로 내보낼까요?")
            .setMessage("방문한 출처 주소, 선택 문장, 의견, 철회 이력이 포함됩니다. 다른 사람에게 파일을 전달하면 이 내용도 전달됩니다. 서명 개인키와 미승인 초안은 포함하지 않습니다.")
            .setNegativeButton("취소",null).setPositiveButton("파일 선택",(d,w) -> {
                try { String exported=store.exportJSON();
                    try(OutputStream file=openFileOutput("pending-export.json", MODE_PRIVATE)) { file.write(exported.getBytes(StandardCharsets.UTF_8)); }
                    Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT); i.addCategory(Intent.CATEGORY_OPENABLE); i.setType("application/json"); i.putExtra(Intent.EXTRA_TITLE,"human-browser-records.json"); startActivityForResult(i,40); }
                catch(Exception e){ toast("내보내기 실패: "+e.getMessage()); }
            }).show();
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if(request==40 && result==RESULT_OK && data!=null && getFileStreamPath("pending-export.json").isFile()) {
            try(OutputStream out=getContentResolver().openOutputStream(data.getData(),"wt")) {
                if(out==null) throw new IOException("파일을 열 수 없습니다."); try(InputStream input=openFileInput("pending-export.json")) { byte[] buffer=new byte[8192]; int count; while((count=input.read(buffer))!=-1) out.write(buffer,0,count); }
                toast("기록 파일을 저장했습니다.");
            } catch(Exception e){ toast("내보내기 실패: "+e.getMessage()); }
        } if(request==40) deleteFile("pending-export.json");
    }
    private void clearDraft(){ draft=null; draftToken=UUID.randomUUID().toString(); persistDraft(); status.setText("이 기기에서 직접 탐색 · 기록은 로컬 보관"); }
    private void persistDraft(){ getPreferences(MODE_PRIVATE).edit().putString("draft",draft==null?"":draft.toString()).apply(); }
    @Override protected void onResume(){ super.onResume(); handler.post(observe); if(web!=null) web.onResume(); }
    @Override protected void onPause(){ handler.removeCallbacks(observe); persistDraft(); if(web!=null) web.onPause(); super.onPause(); }
    @Override protected void onDestroy(){ handler.removeCallbacksAndMessages(null); if(editor!=null) editor.dismiss(); if(web!=null){root.removeView(web);web.destroy();} network.shutdown(); if(store!=null) store.close();super.onDestroy(); }
    @Override public void onBackPressed(){ if(expanded){togglePanel();return;} if(web.canGoBack()){web.goBack();return;}super.onBackPressed(); }
    private void addChoice(LinearLayout parent,String label,String key,String[] values){
        parent.addView(text(label,12,MUTED)); Spinner s=spinner(values,indexOf(values,draft.optString(key)));parent.addView(s);
        s.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){ public void onNothingSelected(AdapterView<?>p){} public void onItemSelected(AdapterView<?>p,View v,int pos,long id){if(draft!=null){put(draft,key,values[pos]);persistDraft();}}});
    }
    private Spinner spinner(String[] values,int index){Spinner s=new Spinner(this); ArrayAdapter<String>a=new ArrayAdapter<>(this,android.R.layout.simple_spinner_item,values);a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);s.setAdapter(a);s.setSelection(Math.max(0,index));return s;}
    private int indexOf(String[] a,String v){for(int i=0;i<a.length;i++)if(a[i].equals(v))return i;return 0;}
    private String label(String k){return labels[indexOf(kinds,k)];}
    private void put(JSONObject o,String k,String v){try{o.put(k,v==null?"":v);}catch(JSONException e){throw new IllegalStateException(e);}}
    private TextWatcher watcher(Runnable change){return new TextWatcher(){public void beforeTextChanged(CharSequence s,int a,int c,int f){}public void onTextChanged(CharSequence s,int a,int b,int c){change.run();}public void afterTextChanged(Editable e){}};}
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private LinearLayout vertical(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);return l;}
    private LinearLayout row(){LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    private TextView text(String s,int size,int color){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);t.setTextColor(color);t.setPadding(0,dp(4),0,dp(4));t.setLineSpacing(dp(2),1);return t;}
    private Button button(String label,View.OnClickListener listener){Button b=new Button(this,null,android.R.attr.borderlessButtonStyle);b.setText(label);b.setTextSize(12);b.setAllCaps(false);b.setTextColor(GREEN);b.setMinWidth(0);b.setMinimumWidth(0);b.setPadding(dp(8),0,dp(8),0);b.setOnClickListener(listener);return b;}
    private void addAction(LinearLayout row,String text,View.OnClickListener listener){row.addView(button(text,listener),new LinearLayout.LayoutParams(0,dp(46),1));}
    private GradientDrawable round(int color){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(12));return d;}
    private void toast(String text){Toast.makeText(this,text,Toast.LENGTH_LONG).show();}
}
