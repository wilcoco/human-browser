package org.humanbrowser.android.browsertests;
import android.app.*;
import android.content.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Offline queue and disclosure checks. All records are explicitly synthetic. */
public final class PublicChecks extends BrowserChecks {
 @Override public void onStart(){Bundle result=new Bundle();try{
  Intent intent=new Intent(Intent.ACTION_MAIN).setClassName("org.humanbrowser.android","org.humanbrowser.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
  activity=startActivitySync(intent);waitUntil(()->(Boolean)field("pageReady"),"page loads");
  Object api=field("publicApi"), store=field("store");
  require(!(Boolean)field("publicMode"),"public lookup is off by default");
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"startup never uploads private history");
  JSONObject draft=new JSONObject();draft.put("url","https://human-browser.invalid/automated-validation");draft.put("title","자동화 검증용 합성 데이터");draft.put("quote","사람의 판단 💬 / 검토");draft.put("kind","comment");draft.put("text","자동화 검증용 기록입니다. 실제 사람의 의견이 아닙니다.");
  JSONObject record=(JSONObject)store.getClass().getMethod("commit",JSONObject.class).invoke(store,draft);
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"local save does not enqueue a public post");
  onMain(()->invoke("confirmPublish",new Class[]{JSONObject.class},record));
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"review alone does not publish");
  screenshot("android-public-confirm.png");clickVisibleText("취소");
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"cancel preserves private scope");
  onMain(()->invoke("switchPublicMode",new Class[]{}));
  require(!(Boolean)field("publicMode"),"lookup notice does not enable network mode");clickVisibleText("취소");
  require(!(Boolean)field("publicMode"),"lookup cancellation stays private");
  // Persist a synthetic approved event without network. Exercise process-independent queue storage.
  api.getClass().getMethod("enqueue",JSONObject.class).invoke(api,record);
  Object reopened=api.getClass().getConstructor(Context.class).newInstance(getTargetContext());
  require((Integer)reopened.getClass().getMethod("pendingCount").invoke(reopened)==1,"approved outbox survives reopening");
  require((Boolean)reopened.getClass().getMethod("wasPublishedOrQueued",String.class).invoke(reopened,record.getString("id")),"pending status prevents losing a withdrawal");
  store.getClass().getMethod("withdraw",String.class).invoke(store,record.getString("id"));
  JSONObject w=(JSONObject)store.getClass().getMethod("withdrawalFor",String.class).invoke(store,record.getString("id"));
  api.getClass().getMethod("enqueue",JSONObject.class).invoke(api,w);
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==2,"withdrawal and original survive as separate retry events");
  require(w.getString("actorId").equals(record.getString("actorId")),"withdrawal retains owner identity");
  String archive=(String)store.getClass().getMethod("exportJSON").invoke(store);
  try(FileOutputStream out=new FileOutputStream(new File(getTargetContext().getExternalFilesDir(null),"android-server-fixture.json"))){out.write(archive.getBytes(StandardCharsets.UTF_8));}
  require(new JSONObject(archive).getJSONArray("records").length()==2,"original and withdrawal retained for cross-runtime verification");
  result.putString("stream","Public approval/queue checks passed: "+checks+"\n");finish(-1,result);
 }catch(Throwable e){result.putString("stream","Public checks FAILED after "+checks+": "+e+"\n");finish(0,result);}}
}
