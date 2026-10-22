package org.humanbrowser.android;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Native HTTPS client. Never exposed to WebView JavaScript. No cookie/website credentials. */
public final class PublicApi {
    public static final String BASE = "https://human-browser-production.up.railway.app";
    private final SharedPreferences state;
    public PublicApi(Context context) { state=context.getApplicationContext().getSharedPreferences("public-api-v1",Context.MODE_PRIVATE); }
    public synchronized boolean wasPublishedOrQueued(String id) { return state.getBoolean("sent:"+id,false)||state.contains("queue:"+id); }
    public synchronized void enqueue(JSONObject record) throws Exception {
        JSONObject checked=RecordStore.verifyExternal(record.toString());
        if(!state.edit().putString("queue:"+checked.getString("id"),checked.toString()).commit()) throw new IOException("공개 요청을 보관하지 못했습니다.");
    }
    public synchronized int pendingCount() { int n=0;for(String k:state.getAll().keySet()) if(k.startsWith("queue:"))n++;return n; }
    public void flush() throws Exception {
        List<JSONObject> pending=new ArrayList<>();
        for(Map.Entry<String,?> entry:state.getAll().entrySet()) if(entry.getKey().startsWith("queue:"))pending.add(new JSONObject((String)entry.getValue()));
        Collections.sort(pending,(a,b)->a.optString("operation").equals(b.optString("operation"))?a.optString("createdAt").compareTo(b.optString("createdAt")):a.optString("operation").equals("record")?-1:1);
        Exception failure=null;
        for(JSONObject r:pending) {
            try { request("POST","/v1/records",r.toString());
            if(!state.edit().putBoolean("sent:"+r.getString("id"),true).remove("queue:"+r.getString("id")).commit()) throw new IOException("서버 접수 상태를 보관하지 못했습니다. 재시도해도 중복 게시되지 않습니다.");
            }catch(Exception e){if(failure==null)failure=e;}
        }
        if(failure!=null)throw failure;
    }
    public JSONObject page(String url, long before) throws Exception {
        JSONObject result=request("GET","/v1/records?url="+URLEncoder.encode(url,"UTF-8")+(before>0?"&before="+before:""),null);
        JSONArray records=result.getJSONArray("records");
        if(records.length()>25 || !url.equals(result.getString("sourceUrl"))) throw new IOException("응답의 출처가 일치하지 않습니다.");
        for(int i=0;i<records.length();i++) {
            JSONObject r=RecordStore.verifyExternal(records.getJSONObject(i).toString());
            if(!url.equals(r.getString("url"))||!"record".equals(r.getString("operation")))throw new IOException("응답 기록이 올바르지 않습니다.");
        }
        return result;
    }
    private JSONObject request(String method,String path,String body) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(BASE+path).openConnection();
        c.setInstanceFollowRedirects(false);c.setConnectTimeout(10000);c.setReadTimeout(15000);c.setRequestMethod(method);
        c.setRequestProperty("Accept","application/json");c.setRequestProperty("User-Agent","HumanBrowserAndroid/0.2.0");
        try {
            if(body!=null) { byte[] bytes=body.getBytes(StandardCharsets.UTF_8);c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");c.setFixedLengthStreamingMode(bytes.length);try(OutputStream out=c.getOutputStream()){out.write(bytes);} }
            int code=c.getResponseCode(); InputStream stream=code>=200&&code<300?c.getInputStream():c.getErrorStream();
            if(stream==null)throw new IOException("서버 응답 "+code);
            ByteArrayOutputStream data=new ByteArrayOutputStream();
            try(InputStream in=stream){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(data.size()+n>8*1024*1024)throw new IOException("응답이 너무 큽니다.");data.write(b,0,n);}}
            JSONObject response=new JSONObject(new String(data.toByteArray(),StandardCharsets.UTF_8));
            if(code<200||code>=300)throw new IOException("서버 "+code+": "+response.optString("error","요청 실패"));return response;
        }finally{c.disconnect();}
    }
}
