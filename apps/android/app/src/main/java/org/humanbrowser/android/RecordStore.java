package org.humanbrowser.android;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.KeyFactory;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.X509EncodedKeySpec;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;

/** Local-only experimental Android records. This is NOT the Mac Ed25519 protocol.
 * A signature binds these bytes to a local key; it does not prove human presence or truth.
 * No network calls or JavaScript bridge belong in this store.
 */
public final class RecordStore extends SQLiteOpenHelper {
    public static final String PROTOCOL = "android-local-alpha/1";
    public static final String ARCHIVE_FORMAT = "android-local-archive/1";
    private static final String KEY_ALIAS = "org.humanbrowser.android.records.p256.v1";
    private static final Object KEY_LOCK = new Object();
    private static final int MAX_RECORDS = 10000;
    private static final int MAX_PAYLOAD_BYTES = 128 * 1024;
    private static final String[] DRAFT_FIELDS = {"url", "title", "quote", "capturedAt", "kind",
            "text", "targetId", "criterion", "value", "disposition", "relation"};
    private static final Set<String> KINDS = new HashSet<>(Arrays.asList(
            "comment", "question", "answer", "evaluation", "relation", "decision"));

    public RecordStore(Context context) {
        super(context.getApplicationContext(), "human-browser-android-v1.sqlite3", null, 1);
    }

    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), "
                + "public_key TEXT NOT NULL)");
        db.execSQL("CREATE TABLE records (sequence INTEGER PRIMARY KEY AUTOINCREMENT, "
                + "id TEXT NOT NULL UNIQUE, actor_id TEXT NOT NULL, source_url TEXT NOT NULL, "
                + "created_at TEXT NOT NULL, operation TEXT NOT NULL, withdrawn_id TEXT NOT NULL, "
                + "payload TEXT NOT NULL, signature TEXT NOT NULL, record_json TEXT NOT NULL)");
        db.execSQL("CREATE INDEX records_source ON records(source_url, sequence)");
        db.execSQL("CREATE INDEX records_withdrawal ON records(withdrawn_id, actor_id, operation)");
        // Append-only at the database layer as well as at the public API.
        db.execSQL("CREATE TRIGGER immutable_records_update BEFORE UPDATE ON records "
                + "BEGIN SELECT RAISE(ABORT, 'Records are immutable'); END");
        db.execSQL("CREATE TRIGGER immutable_records_delete BEFORE DELETE ON records "
                + "BEGIN SELECT RAISE(ABORT, 'Records are immutable'); END");
    }

    @Override public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        throw new IllegalStateException("Unsupported record database version; existing records retained.");
    }

    /** Called only after the native UI previews this draft and receives an explicit save action. */
    public synchronized JSONObject commit(JSONObject draft) throws Exception {
        // Copy only validated immutable strings; never retain the caller's mutable JSONObject.
        JSONObject snapshot = validatedDraft(draft);
        synchronized (KEY_LOCK) {
            SQLiteDatabase db = getWritableDatabase();
            db.beginTransaction();
            try {
                KeyStore.PrivateKeyEntry key = signingKey(db);
                JSONObject record = sign(snapshot, "record", "", key);
                insert(db, record);
                db.setTransactionSuccessful();
                return new JSONObject(record.toString());
            } finally {
                db.endTransaction();
            }
        }
    }

    /** Append an owner-signed withdrawal; retain the original and every prior event. */
    public synchronized void withdraw(String id) throws Exception {
        validateId(id);
        synchronized (KEY_LOCK) {
            SQLiteDatabase db = getWritableDatabase();
            db.beginTransaction();
            try {
                JSONObject original = null;
                try (Cursor cursor = db.rawQuery("SELECT record_json FROM records WHERE id=? AND operation='record'",
                        new String[]{id})) {
                    if (cursor.moveToFirst()) original = verifiedRecord(cursor.getString(0));
                }
                if (original == null) throw invalid("Original record was not found.");
                KeyStore.PrivateKeyEntry key = signingKey(db);
                if (!actorId(key.getCertificate().getPublicKey()).equals(original.getString("actorId"))) {
                    throw invalid("Only records made by this device key can be withdrawn.");
                }
                try (Cursor cursor = db.rawQuery("SELECT id FROM records WHERE operation='withdrawal' "
                        + "AND withdrawn_id=? AND actor_id=?", new String[]{id, original.getString("actorId")})) {
                    if (cursor.moveToFirst()) {
                        db.setTransactionSuccessful();
                        return;
                    }
                }
                JSONObject snapshot = new JSONObject();
                for (String field : DRAFT_FIELDS) snapshot.put(field, original.getString(field));
                for (String field : new String[]{"text", "targetId", "criterion", "value", "disposition", "relation"}) {
                    snapshot.put(field, "");
                }
                insert(db, sign(snapshot, "withdrawal", id, key));
                db.setTransactionSuccessful();
            } finally {
                db.endTransaction();
            }
        }
    }

    /** Latest first. all=true includes every source, but never withdrawn records or withdrawal events. */
    public synchronized JSONArray list(String sourceUrl, boolean all) throws Exception {
        if (!all) validateUrl(sourceUrl);
        SQLiteDatabase db = getReadableDatabase();
        String sql = "SELECT r.record_json FROM records r WHERE r.operation='record' "
                + "AND NOT EXISTS (SELECT 1 FROM records w WHERE w.operation='withdrawal' "
                + "AND w.withdrawn_id=r.id AND w.actor_id=r.actor_id)"
                + (all ? "" : " AND r.source_url=?") + " ORDER BY r.sequence DESC";
        JSONArray result = new JSONArray();
        try (Cursor cursor = db.rawQuery(sql, all ? null : new String[]{sourceUrl})) {
            while (cursor.moveToNext()) result.put(verifiedRecord(cursor.getString(0)));
        }
        return result;
    }

    /** Includes full immutable history and public keys, never private key material. */
    public synchronized String exportJSON() throws Exception {
        SQLiteDatabase db = getReadableDatabase();
        JSONArray records = new JSONArray();
        try (Cursor cursor = db.rawQuery("SELECT record_json FROM records ORDER BY sequence", null)) {
            while (cursor.moveToNext()) records.put(verifiedRecord(cursor.getString(0)));
        }
        JSONObject archive = new JSONObject();
        archive.put("format", ARCHIVE_FORMAT);
        archive.put("protocolVersion", PROTOCOL);
        archive.put("compatibleWithMacArchive", false);
        archive.put("algorithm", "SHA256withECDSA/P-256");
        archive.put("publicKeyEncoding", "base64-X509-SPKI");
        archive.put("signatureEncoding", "base64-ASN1-DER");
        archive.put("canonicalization", "android-fixed-string-json/1");
        archive.put("signatureInput", "UTF-8 bytes of each record's signedPayload string");
        archive.put("publicKey", pinnedPublicKey(db));
        archive.put("exportedAt", Instant.now().toString());
        archive.put("records", records);
        return archive.toString(2);
    }

    private static JSONObject validatedDraft(JSONObject draft) throws Exception {
        if (draft == null) throw invalid("A draft is required.");
        Set<String> allowed = new HashSet<>(Arrays.asList(DRAFT_FIELDS));
        Iterator<String> keys = draft.keys();
        while (keys.hasNext()) if (!allowed.contains(keys.next())) throw invalid("Unknown draft field.");
        JSONObject result = new JSONObject();
        for (String field : DRAFT_FIELDS) {
            Object raw = draft.has(field) ? draft.get(field) : "";
            if (!(raw instanceof String)) throw invalid(field + " must be a string.");
            String value = (String) raw;
            validateUnicode(value);
            int limit = (field.equals("text") || field.equals("quote")) ? 32768
                    : field.equals("url") ? 8192 : 2048;
            if (value.getBytes(StandardCharsets.UTF_8).length > limit) throw invalid(field + " is too long.");
            result.put(field, value);
        }
        validateUrl(result.getString("url"));
        String capturedAt = result.getString("capturedAt");
        result.put("capturedAt", capturedAt.isEmpty() ? Instant.now().toString() : capturedAt);
        try { Instant.parse(result.getString("capturedAt")); }
        catch (RuntimeException error) { throw invalid("capturedAt must be an ISO-8601 instant."); }
        String kind = result.getString("kind");
        if (!KINDS.contains(kind)) throw invalid("Unsupported record kind.");
        if (Arrays.asList("comment", "question", "answer", "relation").contains(kind)
                && blank(result.getString("text"))) throw invalid("This record kind requires text.");
        if (kind.equals("evaluation")) {
            if (blank(result.getString("criterion")) || blank(result.getString("value"))) {
                throw invalid("Evaluation requires a criterion and value.");
            }
        } else if (!result.getString("criterion").isEmpty() || !result.getString("value").isEmpty()) {
            throw invalid("Only evaluations can have a criterion and value.");
        }
        String target = result.getString("targetId");
        if (!target.isEmpty()) {
            if (!Arrays.asList("answer", "evaluation", "relation").contains(kind)) {
                throw invalid("This record kind cannot have a target.");
            }
            validateId(target);
        }
        if (kind.equals("relation")) {
            if (target.isEmpty() || blank(result.getString("relation"))) {
                throw invalid("Relation requires a target ID and relation label.");
            }
        } else if (!result.getString("relation").isEmpty()) throw invalid("Only relations can have a relation label.");
        if (!kind.equals("decision") && !result.getString("disposition").isEmpty()) {
            throw invalid("Only decisions can have a disposition.");
        }
        if (kind.equals("decision") && blank(result.getString("disposition"))) {
            throw invalid("Decision requires a disposition.");
        }
        return result;
    }

    private static KeyStore.PrivateKeyEntry signingKey(SQLiteDatabase db) throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        String pinned = pinnedPublicKey(db);
        if (!store.containsAlias(KEY_ALIAS)) {
            if (!pinned.isEmpty() || hasRecords(db)) {
                throw invalid("Signing key is missing. Existing identity was retained; no replacement key was created.");
            }
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                    KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256).build());
            generator.generateKeyPair();
        }
        KeyStore.Entry entry = store.getEntry(KEY_ALIAS, null);
        if (!(entry instanceof KeyStore.PrivateKeyEntry)) throw invalid("Signing key is unavailable.");
        KeyStore.PrivateKeyEntry key = (KeyStore.PrivateKeyEntry) entry;
        String encoded = base64(key.getCertificate().getPublicKey().getEncoded());
        if (!pinned.isEmpty() && !pinned.equals(encoded)) {
            throw invalid("Signing key does not match the saved identity. No records were changed.");
        }
        if (pinned.isEmpty()) {
            if (hasRecords(db)) throw invalid("Identity metadata is missing. No replacement identity was created.");
            ContentValues identity = new ContentValues();
            identity.put("singleton", 1);
            identity.put("public_key", encoded);
            db.insertOrThrow("identity", null, identity);
        }
        return key;
    }

    private static JSONObject sign(JSONObject snapshot, String operation, String withdrawnId,
                                   KeyStore.PrivateKeyEntry key) throws Exception {
        JSONObject record = new JSONObject(snapshot.toString());
        PublicKey publicKey = key.getCertificate().getPublicKey();
        record.put("id", UUID.randomUUID().toString());
        record.put("protocolVersion", PROTOCOL);
        record.put("canonicalization", "android-fixed-string-json/1");
        record.put("algorithm", "SHA256withECDSA/P-256");
        record.put("actorId", actorId(publicKey));
        record.put("publicKey", base64(publicKey.getEncoded()));
        record.put("createdAt", Instant.now().toString());
        record.put("operation", operation);
        record.put("withdrawnRecordId", withdrawnId);
        record.put("quoteDigest", digest(record.getString("quote").getBytes(StandardCharsets.UTF_8)));
        String payload = canonical(record);
        byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_PAYLOAD_BYTES) throw invalid("Record exceeds the payload limit.");
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign((PrivateKey) key.getPrivateKey());
        signer.update(bytes);
        record.put("signature", base64(signer.sign()));
        record.put("signedPayload", payload);
        return verifiedRecord(record.toString());
    }

    private static void insert(SQLiteDatabase db, JSONObject record) throws Exception {
        // Reserve room for one withdrawal per original even when the new-record limit is reached.
        try (Cursor cursor = db.rawQuery("SELECT COUNT(*) FROM records WHERE operation='record'", null)) {
            cursor.moveToFirst();
            if (record.getString("operation").equals("record") && cursor.getLong(0) >= MAX_RECORDS) {
                throw invalid("Local history limit reached. Export your records.");
            }
        }
        ContentValues values = new ContentValues();
        values.put("id", record.getString("id"));
        values.put("actor_id", record.getString("actorId"));
        values.put("source_url", record.getString("url"));
        values.put("created_at", record.getString("createdAt"));
        values.put("operation", record.getString("operation"));
        values.put("withdrawn_id", record.getString("withdrawnRecordId"));
        values.put("payload", record.getString("signedPayload"));
        values.put("signature", record.getString("signature"));
        values.put("record_json", record.toString());
        db.insertOrThrow("records", null, values);
    }

    private static JSONObject verifiedRecord(String json) throws Exception {
        JSONObject record = new JSONObject(json);
        JSONObject payload = new JSONObject(record.toString());
        payload.remove("signature");
        payload.remove("signedPayload");
        String canonical = canonical(payload);
        if (!canonical.equals(record.getString("signedPayload"))
                || !PROTOCOL.equals(record.getString("protocolVersion"))) {
            throw invalid("Saved payload does not match its signed bytes.");
        }
        byte[] keyBytes = Base64.decode(record.getString("publicKey"), Base64.NO_WRAP);
        PublicKey key = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(keyBytes));
        if (!actorId(key).equals(record.getString("actorId"))) throw invalid("Saved actor identity does not match its key.");
        Signature verifier = Signature.getInstance("SHA256withECDSA");
        verifier.initVerify(key);
        verifier.update(canonical.getBytes(StandardCharsets.UTF_8));
        if (!verifier.verify(Base64.decode(record.getString("signature"), Base64.NO_WRAP))) {
            throw invalid("Saved record signature is invalid.");
        }
        return record;
    }

    /** Fixed string-only JSON: ASCII-sorted keys, JSONObject string escaping, no Unicode normalization. */
    private static String canonical(JSONObject object) throws Exception {
        TreeMap<String, String> fields = new TreeMap<>();
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            Object value = object.get(key);
            if (!(value instanceof String)) throw invalid("Signed payload values must be strings.");
            fields.put(key, (String) value);
        }
        StringBuilder result = new StringBuilder("{");
        boolean first = true;
        for (java.util.Map.Entry<String, String> entry : fields.entrySet()) {
            if (!first) result.append(',');
            first = false;
            result.append(JSONObject.quote(entry.getKey())).append(':').append(JSONObject.quote(entry.getValue()));
        }
        return result.append('}').toString();
    }

    private static String pinnedPublicKey(SQLiteDatabase db) {
        try (Cursor cursor = db.rawQuery("SELECT public_key FROM identity WHERE singleton=1", null)) {
            return cursor.moveToFirst() ? cursor.getString(0) : "";
        }
    }

    private static boolean hasRecords(SQLiteDatabase db) {
        try (Cursor cursor = db.rawQuery("SELECT 1 FROM records LIMIT 1", null)) { return cursor.moveToFirst(); }
    }

    private static void validateUrl(String url) throws Exception {
        if (url == null || url.isEmpty() || url.getBytes(StandardCharsets.UTF_8).length > 8192) {
            throw invalid("A valid source URL is required.");
        }
        URI uri;
        try { uri = new URI(url); }
        catch (Exception error) { throw invalid("Invalid source URL."); }
        if (!("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme()))
                || uri.getHost() == null || uri.getHost().isEmpty() || uri.getRawUserInfo() != null) {
            throw invalid("Source must be an HTTP or HTTPS URL without embedded credentials.");
        }
        // https://human-browser.invalid/demo is the dedicated local demo source identity.
    }

    private static void validateId(String id) throws Exception {
        try {
            if (id == null || !UUID.fromString(id).toString().equals(id)) throw invalid("Target must be an exact record UUID.");
        } catch (IllegalArgumentException error) { throw invalid("Target must be an exact record UUID."); }
    }

    private static void validateUnicode(String value) throws Exception {
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == 0) throw invalid("NUL characters are not allowed.");
            if (Character.isHighSurrogate(c)) {
                if (++i >= value.length() || !Character.isLowSurrogate(value.charAt(i))) {
                    throw invalid("Invalid Unicode text.");
                }
            } else if (Character.isLowSurrogate(c)) throw invalid("Invalid Unicode text.");
        }
    }

    private static boolean blank(String value) {
        return value.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    private static String actorId(PublicKey key) throws Exception { return "actor:" + digest(key.getEncoded()); }
    private static String base64(byte[] bytes) { return Base64.encodeToString(bytes, Base64.NO_WRAP); }
    private static String digest(byte[] bytes) throws Exception {
        StringBuilder hex = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            hex.append(Character.forDigit((value >>> 4) & 15, 16)).append(Character.forDigit(value & 15, 16));
        }
        return hex.toString();
    }
    private static Exception invalid(String message) { return new Exception(message); }
}
