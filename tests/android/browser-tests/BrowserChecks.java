package org.humanbrowser.android.browsertests;
import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.webkit.*;
import android.graphics.Bitmap;
import org.json.*;
import java.io.*;
import java.lang.reflect.*;
import java.util.concurrent.*;

/** Explicitly automated synthetic interactions in an isolated emulator; never real human testimony. */
public class BrowserChecks extends Instrumentation {
    Activity activity; int checks;
    interface Work { void run() throws Exception; }
    interface Condition { boolean get() throws Exception; }
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){
        Bundle result=new Bundle();
        try {
            Intent intent=new Intent(Intent.ACTION_MAIN).setClassName("org.humanbrowser.android","org.humanbrowser.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity=startActivitySync(intent);
            waitUntil(() -> (Boolean)field("pageReady"),"demo page loads");
            require(((String)field("currentUrl")).equals("https://human-browser.invalid/demo"),"native URL tracks demo");
            require(count()==0,"visiting page does not create a record");
            screenshot("android-browser-home.png");
            onMain(() -> invoke("beginDraft",new Class[]{boolean.class},false));
            waitUntil(() -> field("editor")!=null && ((AlertDialog)field("editor")).isShowing(),"native editor opens");
            onMain(() -> { EditText body=findEdit(((AlertDialog)field("editor")).getWindow().getDecorView()); body.setText("Automated synthetic note A"); });
            require(count()==0,"typing does not approve a record");
            onMain(() -> ((AlertDialog)field("editor")).getButton(-2).performClick());
            onMain(() -> invoke("navigate",new Class[]{String.class},"https://human-browser.invalid/demo/other"));
            waitUntil(() -> (Boolean)field("pageReady") && ((String)field("currentUrl")).endsWith("/other"),"second page loads");
            require(((JSONObject)field("draft")).getString("url").equals("https://human-browser.invalid/demo"),"draft source stays at A while browsing B");
            onMain(() -> invoke("showEditor",new Class[]{}));
            onMain(() -> ((AlertDialog)field("editor")).getButton(-1).performClick());
            require(count()==0,"review screen is not approval");
            // Confirm through the actual top native dialog, using Instrumentation UI events.
            clickVisibleText("확인하고 저장");
            waitUntil(() -> count()==1,"explicit confirmation saves exactly once");
            require(field("draft")==null,"approved draft cleared");
            JSONObject saved=records().getJSONObject(0);
            require(saved.getString("url").equals("https://human-browser.invalid/demo"),"saved source is frozen A");
            require(saved.getString("text").equals("Automated synthetic note A"),"approved body persisted");
            onMain(() -> invoke("targetRecord",new Class[]{JSONObject.class,String.class},saved,"evaluation"));
            onMain(() -> ((AlertDialog)field("editor")).getButton(-1).performClick());
            clickVisibleText("확인하고 저장");
            waitUntil(() -> count()==2,"evaluation of a specific record saves");
            JSONObject evaluation=records().getJSONObject(0);
            require(evaluation.getString("targetId").equals(saved.getString("id")),"evaluation retains exact target");
            onMain(() -> invoke("beginDraft",new Class[]{boolean.class},false));
            onMain(() -> { EditText body=findEdit(((AlertDialog)field("editor")).getWindow().getDecorView()); body.setText("Draft survives recreation"); ((AlertDialog)field("editor")).getButton(-2).performClick(); });
            JSONObject before=new JSONObject(((JSONObject)field("draft")).toString());
            onMain(() -> activity.finish());
            activity=startActivitySync(intent);
            waitUntil(() -> (Boolean)field("pageReady"),"restarted browser loads");
            require(((JSONObject)field("draft")).getString("text").equals(before.getString("text")),"draft body survives activity restart");
            require(((JSONObject)field("draft")).getString("url").equals(before.getString("url")),"draft source survives activity restart");
            onMain(() -> invoke("navigate",new Class[]{String.class},"javascript:alert(1)"));
            require(((String)field("currentUrl")).equals("https://human-browser.invalid/demo"),"non-web address blocked");
            require(records().length()==2,"navigation does not create approval");
            onMain(() -> { Object store=field("store"); store.getClass().getMethod("withdraw",String.class).invoke(store,saved.getString("id")); invoke("refreshRecords",new Class[]{}); });
            require(count()==1,"withdraw hides original while preserving evaluation");
            onMain(() -> { invoke("clearDraft",new Class[]{}); invoke("navigate",new Class[]{String.class},"https://human-browser.invalid/demo"); });
            waitUntil(() -> (Boolean)field("pageReady"),"demo returns");
            // Selection is synthesized solely by the test, not a production bridge.
            js("(function(){var r=document.createRange();r.selectNodeContents(document.getElementById('selection-a'));var s=window.getSelection();s.removeAllRanges();s.addRange(r);return s.toString();})()");
            onMain(() -> invoke("beginDraft",new Class[]{boolean.class},true));
            waitUntil(() -> field("draft")!=null,"selected passage captured");
            require(((JSONObject)field("draft")).getString("quote").contains("도구를 도입할지"),"quote text retained");
            require(count()==1,"capture alone creates no record");
            screenshot("android-browser-draft.png");
            onMain(() -> ((AlertDialog)field("editor")).getButton(-2).performClick());
            require(js("typeof window.HumanBrowser").equals("\"undefined\""),"no native bridge exposed");
            onMain(() -> { invoke("clearDraft",new Class[]{}); invoke("navigate",new Class[]{String.class},"https://example.com"); });
            waitUntil(() -> (Boolean)field("pageReady") && ((String)field("currentUrl")).startsWith("https://example.com"),"external HTTPS browsing loads");
            screenshot("android-browser-external.png");
            result.putString("stream","Browser integration checks passed: "+checks+"\n");finish(-1,result);
        }catch(Throwable error){ result.putString("stream","Browser integration FAILED after "+checks+": "+error+"\n");finish(0,result); }
    }
    Object field(String name)throws Exception{Field f=activity.getClass().getDeclaredField(name);f.setAccessible(true);return f.get(activity);}
    Object invoke(String name,Class<?>[] types,Object...args)throws Exception{Method m=activity.getClass().getDeclaredMethod(name,types);m.setAccessible(true);return m.invoke(activity,args);}
    void onMain(Work work)throws Exception{final Throwable[] failure={null};runOnMainSync(()->{try{work.run();}catch(Throwable e){failure[0]=e;}});waitForIdleSync();if(failure[0]!=null)throw new Exception(failure[0]);}
    JSONArray records()throws Exception{Object store=field("store");return (JSONArray)store.getClass().getMethod("list",String.class,boolean.class).invoke(store,null,true);}
    int count()throws Exception{return records().length();}
    void require(boolean yes,String message)throws Exception{if(!yes)throw new Exception(message);checks++;}
    void waitUntil(Condition condition,String message)throws Exception{long end=System.currentTimeMillis()+25000;while(System.currentTimeMillis()<end){if(condition.get()){checks++;return;}Thread.sleep(100);}throw new Exception("Timed out: "+message);}
    EditText findEdit(View v)throws Exception{if(v instanceof EditText)return(EditText)v;if(v instanceof ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++){try{return findEdit(g.getChildAt(i));}catch(Exception ignored){}}}throw new Exception("Editor not found");}
    void clickVisibleText(String text)throws Exception{
        android.view.accessibility.AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow();
        if(root==null)throw new Exception("No active native window");
        java.util.List<android.view.accessibility.AccessibilityNodeInfo> found=root.findAccessibilityNodeInfosByText(text);
        for(android.view.accessibility.AccessibilityNodeInfo n:found){if(text.contentEquals(n.getText())&&n.isClickable()){n.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);waitForIdleSync();return;}}
        throw new Exception("Native action missing: "+text);
    }
    String js(String script)throws Exception{CountDownLatch latch=new CountDownLatch(1);String[] value={null};onMain(()->((WebView)field("web")).evaluateJavascript(script,r->{value[0]=r;latch.countDown();}));if(!latch.await(10,TimeUnit.SECONDS))throw new Exception("JS callback timeout");return value[0];}
    void screenshot(String name)throws Exception{waitForIdleSync(); SystemClock.sleep(700); Bitmap b=getUiAutomation().takeScreenshot();if(b==null)return;File file=new File(getTargetContext().getExternalFilesDir(null),name);try(FileOutputStream out=new FileOutputStream(file)){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();}
}
