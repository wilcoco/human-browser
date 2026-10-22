package org.humanbrowser.android.browsertests;
import android.app.*;
import android.content.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Runs only in the disposable emulator. All public posts explicitly identify themselves as tests. */
public final class OnlineChecks extends BrowserChecks {
 String stage;
 @Override public void onCreate(Bundle args){stage=args.getString("stage","online");super.onCreate(args);}
 @Override public void onStart(){Bundle result=new Bundle();JSONObject original=null,evaluation=null;Object store=null,api=null;
 try{
  Intent intent=new Intent(Intent.ACTION_MAIN).setClassName("org.humanbrowser.android","org.humanbrowser.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
  activity=startActivitySync(intent);onMain(()->activity.getWindow().addFlags(128|4194304|2097152|524288));waitUntil(()->(Boolean)field("pageReady"),"demo loads");store=field("store");
  File fixture=new File(getTargetContext().getExternalFilesDir(null),"upgrade-fixture.json");
  if(stage.equals("seed")){
   JSONObject draft=new JSONObject();draft.put("url","https://human-browser.invalid/demo");draft.put("kind","decision");draft.put("disposition","보류");draft.put("title","자동화 업데이트·공유 검증");draft.put("text","자동화 시험 기록입니다. 실제 사람의 판단이 아닙니다.");draft.put("quote","공유 시험용 합성 근거");
   original=(JSONObject)store.getClass().getMethod("commit",JSONObject.class).invoke(store,draft);
   try(FileOutputStream out=new FileOutputStream(fixture)){out.write(original.toString().getBytes(StandardCharsets.UTF_8));}
   require(count()==1,"old version saves one upgrade fixture");
   result.putString("stream","Upgrade seed checks passed: "+checks+"\n");finish(-1,result);return;
  }
  ByteArrayOutputStream bytes=new ByteArrayOutputStream();try(InputStream in=new FileInputStream(fixture)){byte[] b=new byte[4096];int n;while((n=in.read(b))!=-1)bytes.write(b,0,n);}
  JSONObject old=new JSONObject(new String(bytes.toByteArray(),StandardCharsets.UTF_8));original=records().getJSONObject(0);
  require(original.getString("id").equals(old.getString("id")),"upgrade keeps record ID");
  require(original.getString("signature").equals(old.getString("signature")),"upgrade keeps signed payload and identity");
  api=field("publicApi");require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"upgrade never auto-publishes");
  final JSONObject first=original;
  onMain(()->invoke("confirmPublish",new Class[]{JSONObject.class},first));clickVisibleText("확인하고 공개");
  waitUntil(()->!(Boolean)field("publicBusy"),"native publication finishes");
  require((Integer)api.getClass().getMethod("pendingCount").invoke(api)==0,"server acknowledges publication");
  Object independent=api.getClass().getConstructor(Context.class).newInstance(getTargetContext());
  require(find(independent,first)!=null,"independent HTTP reader sees the published judgment");
  require(find(independent,first).getString("disposition").equals("보류"),"judgment status preserved");
  require(find(independent,first).getString("quote").equals(first.getString("quote")),"quoted evidence preserved");
  onMain(()->{if(!(Boolean)field("expanded"))invoke("togglePanel",new Class[]{});invoke("switchPublicMode",new Class[]{});});clickVisibleText("공개 보기");
  waitUntil(()->hasText((android.view.View)field("recordsBox"),first.getString("text")),"shared judgment rendered in native panel");
  screenshot("android-shared-judgment.png");
  onMain(()->invoke("targetRecord",new Class[]{JSONObject.class,String.class},first,"evaluation"));
  onMain(()->((AlertDialog)field("editor")).getButton(-1).performClick());clickVisibleText("확인하고 저장");
  waitUntil(()->count()==2,"evaluation is locally approved");evaluation=records().getJSONObject(0);
  require(evaluation.getString("actorId").equals(old.getString("actorId")),"upgrade retains usable signing key");
  require(evaluation.getString("targetId").equals(first.getString("id")),"evaluation targets exact shared judgment");
  final JSONObject second=evaluation;onMain(()->invoke("confirmPublish",new Class[]{JSONObject.class},second));clickVisibleText("확인하고 공개");
  waitUntil(()->!(Boolean)field("publicBusy"),"evaluation publication finishes");require(find(independent,second)!=null,"independent reader sees shared evaluation");
  onMain(()->invoke("withdrawRecord",new Class[]{JSONObject.class},first));waitUntil(()->!(Boolean)field("publicBusy"),"owner withdrawal completes");
  require(find(independent,first)==null,"withdrawn judgment disappears from server list");require(find(independent,second)!=null,"withdrawal preserves separate evaluation");
  result.putString("stream","Online and upgrade checks passed: "+checks+"\n");
 }catch(Throwable e){result.putString("stream","Online checks FAILED after "+checks+": "+e+"\n");}
 finally{
  if(api!=null&&store!=null){try{for(JSONObject r:new JSONObject[]{original,evaluation})if(r!=null){store.getClass().getMethod("withdraw",String.class).invoke(store,r.getString("id"));JSONObject w=(JSONObject)store.getClass().getMethod("withdrawalFor",String.class).invoke(store,r.getString("id"));api.getClass().getMethod("enqueue",JSONObject.class).invoke(api,w);}api.getClass().getMethod("flush").invoke(api);result.putString("cleanup","Synthetic server posts withdrawn");}catch(Throwable e){result.putString("cleanup","Cleanup requires attention: "+e);}}
 }
 finish(result.getString("stream","").contains("FAILED")?0:-1,result);
 }
 @Override void clickVisibleText(String text)throws Exception{long until=System.currentTimeMillis()+10000;Exception last=null;while(System.currentTimeMillis()<until){try{super.clickVisibleText(text);return;}catch(Exception e){last=e;Thread.sleep(150);}}throw last;}
 JSONObject find(Object client,JSONObject expected)throws Exception{JSONObject page=(JSONObject)client.getClass().getMethod("page",String.class,long.class).invoke(client,expected.getString("url"),0L);JSONArray rows=page.getJSONArray("records");for(int i=0;i<rows.length();i++)if(rows.getJSONObject(i).getString("id").equals(expected.getString("id")))return rows.getJSONObject(i);return null;}
 boolean hasText(android.view.View view,String text){if(view instanceof android.widget.TextView&&((android.widget.TextView)view).getText().toString().contains(text))return true;if(view instanceof android.view.ViewGroup){android.view.ViewGroup group=(android.view.ViewGroup)view;for(int i=0;i<group.getChildCount();i++)if(hasText(group.getChildAt(i),text))return true;}return false;}
}
