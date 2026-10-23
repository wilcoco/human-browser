package org.humanbrowser.android.browsertests;
import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.webkit.*;
import android.widget.*;
import org.json.*;
import java.lang.reflect.*;

/** Synthetic navigation only: no public opinions or approvals are generated. */
public final class NavigationChecks extends BrowserChecks {
 String stage;
 final String demo="https://human-browser.invalid/demo";
 @Override public void onCreate(Bundle args){stage=args.getString("stage","checks");super.onCreate(args);}
 @Override public void onStart(){Bundle result=new Bundle();try{
  activity=startActivitySync(new Intent(Intent.ACTION_MAIN).setClassName("org.humanbrowser.android","org.humanbrowser.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
  onMain(()->activity.getWindow().addFlags(128|4194304|2097152|524288));
  waitUntil(()->(Boolean)field("pageReady"),"demo loaded");
  if(stage.equals("probe")){
   enter("www.naver.com");waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).contains("naver.com"),"naver input opens");
   result.putString("stream","Naver URL: "+field("currentUrl")+"\n"+js("JSON.stringify({title:document.title,text:document.body.innerText.slice(0,1000),links:Array.from(document.querySelectorAll('a[href]')).slice(0,50).map(a=>({text:a.innerText,href:a.href,target:a.target}))})")+"\n");
   screenshot("android-naver-probe.png");finish(-1,result);return;
  }
  if(stage.equals("cafe-probe")){
   enter("https://m.cafe.naver.com/");waitUntil(()->(Boolean)field("pageReady"),"cafe loaded");SystemClock.sleep(5000);
   result.putString("stream",js("JSON.stringify({url:location.href,title:document.title,text:document.body.innerText,html:document.body.innerHTML.slice(0,2500),ua:navigator.userAgent})")+"\n");finish(-1,result);return;
  }
  int before=count();
  expect("www.naver.com","https://www.naver.com");
  expect("HTTPS://WWW.NAVER.COM","https://www.naver.com");
  expect("\u200b\ufeffhttps://www.naver.com\u00a0\u200e","https://www.naver.com");
  expect("www.naver.com:443/path?q=https://example.com","https://www.naver.com:443/path?q=https://example.com");
  expect("https://example.com/a b?q=a%2Fb&x=2#part","https://example.com/a%20b?q=a%2Fb&x=2#part");
  expect("//www.naver.com","https://www.naver.com");
  expect("http://www.naver.com","https://www.naver.com");
  expect("\"https://www.naver.com\"","https://www.naver.com");
  expect("https://한글.kr","https://xn--bj0bj06e.kr");
  expect("https://[::1]:443/a","https://[::1]:443/a");
  require(normalize("사람 브라우저").startsWith("https://duckduckgo.com/?q="),"search input remains search");
  for(String invalid:new String[]{"javascript:alert(1)","file:///etc/passwd","https://user@example.com","https://exa mple.com","https://example.com:wrong","https://example.com\\@evil.com","https:///"}){
   boolean rejected=false;try{normalize(invalid);}catch(InvocationTargetException e){rejected=true;}require(rejected,"reject invalid input "+invalid);
  }
  onMain(()->invoke("beginDraft",new Class[]{boolean.class},false));
  onMain(()->((AlertDialog)field("editor")).getButton(-2).performClick());
  JSONObject draft=(JSONObject)field("draft");
  popup("<a id='go' href='"+demo+"/other' target='_blank'>추가 메뉴</a>");
  require(((String)field("currentUrl")).equals(demo+"/other"),"target blank changes active URL");
  require(((EditText)field("address")).getText().toString().equals(demo+"/other"),"address displays child URL");
  require(((JSONObject)field("draft")).getString("url").equals(draft.getString("url")),"popup keeps draft source frozen");
  back();require(((String)field("currentUrl")).equals(demo),"back returns to opener");
  popup("<button id='go' onclick=\"window.open('"+demo+"/other','_blank')\">추가 메뉴</button>");
  back();
  popup("<button id='go' onclick=\"var w=window.open('about:blank');setTimeout(function(){w.location='"+demo+"/other'},300)\">추가 메뉴</button>");
  js("window.close()");waitUntil(()->((String)field("currentUrl")).equals(demo),"window close returns to opener");
  popup("<form action='"+demo+"/other' target='_blank' method='post'><input name='sample' value='navigation-test'><button id='go'>전송</button></form>");
  back();
  js("window.open('"+demo+"/other','_blank')");SystemClock.sleep(700);
  require(((java.util.List)field("windows")).size()==1,"unrequested popups remain blocked");
  js("history.pushState({},'', '/demo#section')");waitUntil(()->((String)field("currentUrl")).endsWith("#section"),"SPA URL stays synchronized");
  onMain(()->invoke("clearDraft",new Class[]{}));
  enter("www.naver.com");waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).contains("naver.com"),"bare naver address opens actual website");
  require(js("document.title").contains("NAVER")||js("document.title").contains("네이버"),"Naver content is rendered");
  screenshot("android-naver-fixed.png");
  result.putString("naverLinks",js("JSON.stringify(Array.from(document.querySelectorAll('a[href]')).filter(a=>a.innerText.trim()).slice(0,45).map(a=>({text:a.innerText,href:a.href,target:a.target})))"));
  tap("a[href$='/aside/']");
  waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).contains("/aside"),"Naver expanded menu opens by tapping");
  screenshot("android-naver-menu-fixed.png");
  result.putString("menuLinks",js("JSON.stringify(Array.from(document.querySelectorAll('a[href]')).filter(a=>a.innerText.trim()).slice(0,45).map(a=>({text:a.innerText,href:a.href,target:a.target})))"));
  tap("a[href*='m.cafe.naver.com']");
  waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).contains("cafe.naver.com"),"Naver menu service link opens by tapping");
  // URL routing is tested here; cafe-probe separately reports site rendering compatibility.
  screenshot("android-naver-cafe-fixed.png");
  require(count()==before,"navigation creates no judgments");
  result.putString("stream","Navigation checks passed: "+checks+"\n");finish(-1,result);
 }catch(Throwable e){result.putString("stream","Navigation FAILED after "+checks+": "+e+"\n");finish(0,result);}}
 String normalize(String value)throws Exception{Class c=Class.forName("org.humanbrowser.android.UrlInput",true,activity.getClassLoader());Method m=c.getDeclaredMethod("fromInput",String.class);m.setAccessible(true);return(String)m.invoke(null,value);}
 void expect(String input,String expected)throws Exception{require(normalize(input).equals(expected),"normalize "+input+" got "+normalize(input));}
 void enter(String value)throws Exception{onMain(()->{EditText address=(EditText)field("address");address.requestFocus();address.setText(value);findButton(activity.getWindow().getDecorView(),"이동").performClick();});}
 Button findButton(View view,String text)throws Exception{if(view instanceof Button&&text.contentEquals(((Button)view).getText()))return(Button)view;if(view instanceof ViewGroup){ViewGroup g=(ViewGroup)view;for(int i=0;i<g.getChildCount();i++)try{return findButton(g.getChildAt(i),text);}catch(Exception ignored){}}throw new Exception("button absent "+text);}
 void popup(String html)throws Exception{
  js("document.body.innerHTML="+JSONObject.quote("<style>body{margin:0}#go{display:block;padding:30px;font-size:20px}</style>"+html));
  tap("#go");waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).equals(demo+"/other"),"gesture popup navigates");
 }
 void back()throws Exception{onMain(()->invoke("goBack",new Class[]{}));waitUntil(()->(Boolean)field("pageReady")&&((String)field("currentUrl")).equals(demo),"opener restored");}
 void tap(String selector)throws Exception{
  js("document.querySelector("+JSONObject.quote(selector)+").scrollIntoView({block:\"center\"})");
  String raw=js("(function(){var r=document.querySelector("+JSONObject.quote(selector)+").getBoundingClientRect();return JSON.stringify([r.left+r.width/2,r.top+r.height/2,innerWidth]);})()");
  JSONArray rect=new JSONArray((String)new JSONTokener(raw).nextValue());
  float[] xy=new float[2];onMain(()->{WebView w=(WebView)field("web");int[] loc=new int[2];w.getLocationOnScreen(loc);float scale=w.getWidth()/(float)rect.getDouble(2);xy[0]=loc[0]+(float)rect.getDouble(0)*scale;xy[1]=loc[1]+(float)rect.getDouble(1)*scale;});
  long now=SystemClock.uptimeMillis();sendPointerSync(MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,xy[0],xy[1],0));sendPointerSync(MotionEvent.obtain(now,now+70,MotionEvent.ACTION_UP,xy[0],xy[1],0));waitForIdleSync();
 }
}
