package org.humanbrowser.android.recordtests;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.util.Base64;
import org.humanbrowser.android.RecordStore;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;

/** Run only in the separate recordtests APK, never against the browser application's sandbox. */
public final class RecordStoreChecks extends Instrumentation {
    private static final String PACKAGE = "org.humanbrowser.android.recordtests";
    private static final String DATABASE = "human-browser-android-v1.sqlite3";
    private static final String KEY = "org.humanbrowser.android.records.p256.v1";
    private int checks;

    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            Context context = getTargetContext();
            require(PACKAGE.equals(context.getPackageName()) && PACKAGE.equals(getContext().getPackageName()),
                    "Tests must run in their isolated test application.");
            context.deleteDatabase(DATABASE);
            KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
            keys.load(null);
            keys.deleteEntry(KEY);
            RecordStore store = new RecordStore(context);
            JSONObject draft = draft("comment", "Original quote").put("text", "A local comment.");
            JSONObject committed = store.commit(draft);
            String id = committed.getString("id");
            draft.put("quote", "Mutated quote");
            committed.put("text", "Mutated return value");
            JSONObject saved = store.list("https://human-browser.invalid/demo", false).getJSONObject(0);
            require(saved.getString("quote").equals("Original quote"), "Draft snapshot is immutable.");
            require(saved.getString("text").equals("A local comment."), "Returned JSON is not retained.");
            verify(saved);
            require(store.list("https://example.org/elsewhere", false).length() == 0, "Exact source filtering.");
            require(store.list(null, true).length() == 1, "All-source listing.");
            store.commit(draft("decision", "").put("disposition", "unresolved"));
            store.commit(draft("evaluation", "").put("criterion", "clarity").put("value", "unclear")
                    .put("targetId", id));
            store.commit(draft("answer", "").put("text", "An answer").put("targetId", id));
            store.commit(draft("relation", "").put("text", "Related example")
                    .put("targetId", id).put("relation", "supports"));
            require(store.list(null, true).length() == 5, "Supported record kinds are saved.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", "  ")), "Blank comment rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", 12)), "Non-string text rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", "ok").put("url", "javascript:alert(1)")),
                    "Non-web URL rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", "ok").put("url", "file:///private/file")),
                    "File URL rejected.");
            expectFailure(() -> store.commit(draft("evaluation", "").put("value", "yes")), "Missing criterion rejected.");
            expectFailure(() -> store.commit(draft("relation", "").put("text", "x").put("targetId", "anything")),
                    "Malformed target rejected.");
            expectFailure(() -> store.commit(draft("decision", "")), "Missing disposition rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", "ok").put("extra", "ignored?")),
                    "Unexpected draft field rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", "\uD800")), "Invalid Unicode rejected.");
            expectFailure(() -> store.commit(draft("comment", "").put("text", new String(new char[32769]).replace('\0', 'x'))),
                    "Oversized text rejected.");
            store.withdraw(id);
            store.withdraw(id);
            JSONArray active = store.list(null, true);
            require(active.length() == 4, "Withdrawal hides exactly the original.");
            JSONObject archive = new JSONObject(store.exportJSON());
            JSONArray history = archive.getJSONArray("records");
            require(history.length() == 6, "Withdrawal is an idempotent append preserving history.");
            require(archive.getString("format").equals("android-local-archive/1"), "Android archive is distinct.");
            require(!archive.getBoolean("compatibleWithMacArchive"), "Mac incompatibility is explicit.");
            for (int i = 0; i < history.length(); i++) verify(history.getJSONObject(i));
            require(history.getJSONObject(5).getString("withdrawnRecordId").equals(id), "Withdrawal binds original ID.");
            expectFailure(() -> store.getWritableDatabase().execSQL("DELETE FROM records"), "History deletion rejected.");
            store.close();
            RecordStore reopened = new RecordStore(context);
            require(reopened.list(null, true).length() == 4, "History survives reopen.");
            keys.deleteEntry(KEY);
            expectFailure(() -> reopened.commit(draft("comment", "").put("text", "Must not save")),
                    "Missing key fails closed.");
            require(!keys.containsAlias(KEY), "Missing key is not silently regenerated.");
            require(reopened.list(null, true).length() == 4, "Missing key still permits reading public history.");
            require(new JSONObject(reopened.exportJSON()).getJSONArray("records").length() == 6,
                    "Missing key still permits full public export.");
            reopened.close();
            result.putString("stream", "RecordStore checks passed: " + checks + "\n");
            finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "RecordStore checks failed after " + checks + ": " + error + "\n");
            finish(0, result);
        }
    }

    private JSONObject draft(String kind, String quote) throws Exception {
        return new JSONObject().put("url", "https://human-browser.invalid/demo").put("title", "Local demo")
                .put("quote", quote).put("capturedAt", "2026-10-22T00:00:00Z").put("kind", kind);
    }

    private void verify(JSONObject record) throws Exception {
        Signature verifier = Signature.getInstance("SHA256withECDSA");
        verifier.initVerify(KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(
                Base64.decode(record.getString("publicKey"), Base64.NO_WRAP))));
        verifier.update(record.getString("signedPayload").getBytes(StandardCharsets.UTF_8));
        require(verifier.verify(Base64.decode(record.getString("signature"), Base64.NO_WRAP)),
                "Public-key verification succeeds independently.");
    }

    private void require(boolean condition, String message) throws Exception {
        if (!condition) throw new Exception(message);
        checks++;
    }
    private void expectFailure(Action action, String message) throws Exception {
        boolean failed = false;
        try { action.run(); } catch (Exception expected) { failed = true; }
        require(failed, message);
    }
    private interface Action { void run() throws Exception; }
}
