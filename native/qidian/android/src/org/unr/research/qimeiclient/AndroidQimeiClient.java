package org.unr.research.qimeiclient;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.provider.Settings;
import android.util.DisplayMetrics;
import java.io.File;
import java.net.NetworkInterface;
import java.util.Enumeration;
import java.util.Locale;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Caller owns privacy consent and account session; use ensure on a worker. */
public final class AndroidQimeiClient implements AutoCloseable {
  public interface Wire extends AutoCloseable {
    String exchange(String form,String[] names,String[] values)throws Exception;
    @Override void close();
  }
  public static final class Session {
    public final String deviceId,userId,token,ywKey,ywGuid,oaid,strategyAndroidId,huaweiReferrer;
    public Session(String deviceId,String userId,String token,String ywKey,String ywGuid,String oaid,String strategyAndroidId,String huaweiReferrer){
      if(deviceId==null||userId==null||token==null||ywKey==null||ywGuid==null||oaid==null||strategyAndroidId==null||huaweiReferrer==null)throw new IllegalArgumentException("Incomplete authorized session");
      this.deviceId=deviceId;this.userId=userId;this.token=token;this.ywKey=ywKey;this.ywGuid=ywGuid;this.oaid=oaid;this.strategyAndroidId=strategyAndroidId;this.huaweiReferrer=huaweiReferrer;
    }
    public static Session anonymous(){return new Session("","0","","","","","","");}
  }
  private static final String APP_KEY="0I000JZU8B16UN21",CHANNEL="10000431",VERSION="7.9.480",WIRE_VERSION="7.9.480.1996";
  private final Context context;
  private final Session session;
  private final Wire transport;
  private final AndroidSnapshot registration;
  private final SharedPreferences history;
  private final String profile;
  private long handle;
  public AndroidQimeiClient(Context context,Session session,boolean consent)throws Exception {
    this(context,session,consent,new AppTransport(),null,null);
  }
  public AndroidQimeiClient(Context context,Session session,boolean consent,boolean allowNetwork)throws Exception {
    this(context,session,consent,allowNetwork?new AppTransport():new Wire(){public String exchange(String form,String[] names,String[] values){throw new IllegalStateException("Registration disabled");}public void close(){}},null,null);
  }
  // Package-private fixtures may supply only the test wire/private filename and
  // a synthetic RSA public key; production uses the fixed bundled profile.
  AndroidQimeiClient(Context context,Session session,boolean consent,Wire wire,String selectedProfile,String testFile)throws Exception {
    if(!consent||context==null||session==null||wire==null)throw new IllegalArgumentException("Client requires consent and context");
    this.context=context.getApplicationContext();this.session=session;this.transport=wire;this.profile=selectedProfile==null?NativeClient.profile():selectedProfile;
    registration=new AndroidSnapshot(this.context,APP_KEY);history=this.context.getSharedPreferences("unr-qimei-client-identity-v1",Context.MODE_PRIVATE);
    File directory=new File(this.context.getFilesDir(),"unr-qimei-client-v1");if(!directory.isDirectory()&&!directory.mkdirs())throw new IllegalStateException("Client private directory unavailable");
    if(testFile!=null&&!testFile.matches("test-[A-Za-z0-9-]+\\.json"))throw new IllegalArgumentException("Test filename invalid");
    handle=NativeClient.create(this,new File(directory,testFile==null?"qimei-state.json":testFile).getAbsolutePath(),profile,true);
  }
  public JSONObject ensure(boolean consent,boolean forceRefresh)throws Exception {
    long selected;synchronized(this){selected=handle;}if(selected==0)throw new IllegalStateException("Client closed");
    return new JSONObject(NativeClient.ensure(selected,consent,forceRefresh));
  }
  public JSONObject headers(JSONObject params,JSONObject account)throws Exception {long selected;synchronized(this){selected=handle;}if(selected==0)throw new IllegalStateException("Client closed");return new JSONObject(NativeClient.headers(selected,params.toString(),account.toString()));}
  public boolean pause(){long selected;synchronized(this){selected=handle;}if(selected==0)throw new IllegalStateException("Client closed");return NativeClient.pause(selected);}
  @Override public void close(){long selected;synchronized(this){selected=handle;handle=0;}if(selected!=0)NativeClient.close(selected);}
  private void cancelTransport(){transport.close();}
  private String exchange(String form,String[] names,String[] values)throws Exception{return transport.exchange(form,names,values);}
  private synchronized String stable(String key)throws Exception {
    String value=history.getString(key,"");if(value==null||value.isEmpty()){value=key.equals("uin")?Long.toString(System.currentTimeMillis())+UUID.randomUUID().toString().replace("-","").substring(0,16):UUID.randomUUID().toString();if(!history.edit().putString(key,value).commit())throw new IllegalStateException("Client identity persistence failed");}return value;
  }
  private String collectSnapshot(String q16,String q36)throws Exception {
    String androidId=Settings.Secure.getString(context.getContentResolver(),Settings.Secure.ANDROID_ID);androidId=androidId==null?"":androidId.toLowerCase(Locale.ROOT);
    String device=session.deviceId.isEmpty()?(androidId.isEmpty()?stable("fallback-device"):androidId):session.deviceId;
    JSONArray packages=new JSONArray();for(PackageInfo info:context.getPackageManager().getInstalledPackages(0))packages.put(info.packageName);
    JSONArray interfaces=new JSONArray();Enumeration<NetworkInterface> networks=NetworkInterface.getNetworkInterfaces();while(networks!=null&&networks.hasMoreElements())interfaces.put(networks.nextElement().getName());
    JSONObject metadata=new JSONObject().put("guid",session.ywGuid).put("qimei",q16).put("qimei36",q36).put("model",Build.MODEL).put("ssid",JSONObject.NULL).put("interfaces",interfaces).put("packages",packages);
    long selected;synchronized(this){selected=handle;}if(selected==0)throw new IllegalStateException("Client collection closed");
    JSONObject report=NativeClient.collectReport(selected,context,metadata,new JSONObject().put("settings",new JSONObject()));
    JSONObject user=new JSONObject().put("userId",session.userId);
    JSONObject packet=registration.collect(new AndroidSnapshot.Inputs(APP_KEY,CHANNEL,"",user,session.oaid,session.strategyAndroidId),profile,true);
    // App API profile declarations are separate from this application's actual
    // installation time, Android properties, package/certificate and probes.
    packet.getJSONObject("common").put("appVersion",WIRE_VERSION).put("processName","com.qidian.QDReader").put("installationUin",stable("uin"));
    JSONObject body=packet.getJSONObject("report");body.put("2","30");JSONObject extra=new JSONObject(body.getString("12"));extra.put("av",WIRE_VERSION).put("ch",CHANNEL);body.put("12",extra.toString());
    boolean xposed=report.optBoolean("obs_isXposedByClass")||report.optBoolean("obs_isXposedByStack")||report.optBoolean("obs_isXposedByMaps");
    boolean emulator=NativeClient.property("sys.tencent.init").equals("1")||"AOSP on Intel Platform".equals(Build.MODEL);
    boolean x86=false;for(String architecture:Build.SUPPORTED_ABIS)x86|=architecture.contains("x86");
    boolean virtual=false;try{Class.forName("com.lody.virtual.client.core.VirtualCore",false,context.getClassLoader());virtual=xposed;}catch(ClassNotFoundException unavailable){}
    // These request flags are fixed declarations, independent of device state.
    JSONObject environment=new JSONObject().put("env",Long.toString(0x100400L)).put("root","0").put("xposed",flag(xposed)).put("emulator",flag(emulator)).put("accessibility","0").put("debug","0").put("autojs","0").put("virtualXposed",flag(virtual)).put("x86",flag(x86));
    DisplayMetrics display=context.getResources().getDisplayMetrics();int bar=24;int dimension=context.getResources().getIdentifier("status_bar_height","dimen","android");if(dimension>0&&display.density>0)bar=Math.round(context.getResources().getDimensionPixelSize(dimension)/display.density);
    JSONObject headersContext=new JSONObject().put("device",device).put("version",VERSION).put("versionCode",1996).put("width",display.widthPixels).put("height",display.heightPixels).put("storedChannel",CHANNEL).put("packageChannel",CHANNEL).put("osRelease",Build.VERSION.RELEASE).put("model",Build.MODEL).put("userId",session.userId).put("androidId",androidId).put("oaid",session.oaid).put("huaweiReferrer",session.huaweiReferrer).put("clientType",1).put("networkType",packet.getJSONObject("common").getString("network").equals("wifi")?1:4).put("emulator",emulator?1:0).put("appFlag",0);
    JSONObject cookies=new JSONObject().put("token",session.token).put("ywKey",session.ywKey).put("ywGuid",session.ywGuid).put("appId","12").put("areaId","30").put("language","cn").put("mode","normal").put("bar",Integer.toString(bar));
    JSONObject headers=new JSONObject().put("context",headersContext).put("environment",environment).put("session",cookies).put("brand",Build.BRAND).put("statusBarDp",bar).put("includeAndroidId",true);
    return new JSONObject().put("registration",packet).put("headers",headers).put("report",report).toString();
  }
  private static String flag(boolean value){return value?"1":"0";}
}
