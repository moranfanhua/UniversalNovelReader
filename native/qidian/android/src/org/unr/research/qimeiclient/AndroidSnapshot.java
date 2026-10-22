package org.unr.research.qimeiclient;

import android.app.Application;
import android.app.UiModeManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;
import android.provider.Settings;
import android.telephony.TelephonyManager;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.Locale;
import org.json.JSONObject;

/** Reads only this application's real context and caller-authorized business data. */
public final class AndroidSnapshot {
  static { System.loadLibrary("qimei_client_android"); initialize(SystemCrypto.class); }
  private static native void initialize(Class<?> helper);
  public static native String nativePlatform();
  public static native String encodeDeviceValue(String profile,String actualValue);
  public static final class Inputs {
    public final String appKey,channel,sdkName,oaid,androidId;
    private final String userJson;
    public Inputs(String appKey,String channel,String sdkName,JSONObject authorizedUserIds,String oaid,String androidId) {
      if(appKey==null||appKey.isEmpty()||channel==null||sdkName==null||authorizedUserIds==null||oaid==null||androidId==null)throw new IllegalArgumentException("Incomplete QIMEI snapshot inputs");
      this.appKey=appKey;this.channel=channel;this.sdkName=sdkName;this.userJson=authorizedUserIds.toString();this.oaid=oaid;this.androidId=androidId;
    }
  }
  private final Context context;
  private final String appKey;
  private final SharedPreferences history;
  private final File marker;
  private String uptimeHistory,bootHistory;
  private Boolean cloneState;
  public AndroidSnapshot(Context context,String appKey)throws Exception {
    this.context=context.getApplicationContext();this.appKey=appKey;
    if(this.context==null||appKey==null||appKey.isEmpty())throw new IllegalArgumentException("QIMEI context unavailable");
    byte[] digest=MessageDigest.getInstance("SHA-256").digest(appKey.getBytes(StandardCharsets.UTF_8));StringBuilder suffix=new StringBuilder();for(byte value:digest)suffix.append(String.format(Locale.ROOT,"%02x",value&255));
    history=this.context.getSharedPreferences("unr-qimei-snapshot-"+suffix,Context.MODE_PRIVATE);
    marker=new File(this.context.getFilesDir(),"unr-qimei-install-"+suffix);
  }
  public synchronized JSONObject collect(Inputs input,String profile,boolean privacyAgreed)throws Exception {
    if(!privacyAgreed)throw new IllegalStateException("QIMEI collection requires privacy consent");
    if(input==null||!appKey.equals(input.appKey))throw new IllegalArgumentException("QIMEI snapshot belongs to another application profile");
    JSONObject platform=new JSONObject(nativePlatform());PackageInfo info=context.getPackageManager().getPackageInfo(context.getPackageName(),0);
    String version=version(info),process=processName(context),secure=Settings.Secure.getString(context.getContentResolver(),Settings.Secure.ANDROID_ID);
    String oz=encodeDeviceValue(profile,secure==null?"":secure.toLowerCase(Locale.ROOT)),oo=encodeDeviceValue(profile,platform.getString("model"));
    if(uptimeHistory==null){List<String> values=split(history.getString("uptimes",""));String bootSeconds=Long.toString((System.currentTimeMillis()-SystemClock.elapsedRealtime())/1000L);if(values.isEmpty()||!values.get(0).equals(bootSeconds))values.add(0,bootSeconds);while(values.size()>5)values.remove(values.size()-1);uptimeHistory=android.text.TextUtils.join(";",values);bootHistory=history.getString("bootids","");if(!history.edit().putString("uptimes",uptimeHistory).commit())throw new IllegalStateException("QIMEI history persistence failed");}
    JSONObject extra=new JSONObject();
    String harmony="0";try{Object brand=Class.forName("com.huawei.system.BuildEx").getMethod("getOsBrand").invoke(null);if(brand!=null)harmony="harmony".equalsIgnoreCase(String.valueOf(brand))?"1":"0";}catch(ReflectiveOperationException ignored){}
    extra.put("harmony",harmony).put("clone",Process.myUid()/100000!=0?"1":"0").put("containe",container()).put("oz",oz).put("oz2","").put("oo",oo).put("kelong",cloneState(info.firstInstallTime)?"1":"0").put("ip",firstIpv4()).put("multiUser",multiUser(context));
    for(String name:new String[]{"bod","brd","dv","firstLevel","manufact","name","host","kernel"})extra.put(name,platform.getString(name));
    ApplicationInfo app=context.getApplicationInfo();int pre=app.flags>=0&&(app.flags&ApplicationInfo.FLAG_SYSTEM)!=0?2:0;if(context.getFilesDir().getAbsolutePath().startsWith("/system"))pre=1;
    extra.put("pre",Integer.toString(pre)).put("av",version).put("ch",ApkChannel.read(new File(app.sourceDir))).put("svr",process.contains(":")?process.substring(process.lastIndexOf(':')+1):"").put("fit",info.firstInstallTime);
    JSONObject body=new JSONObject().put("1",input.channel).put("2",Integer.toString(app.targetSdkVersion)).put("3",input.userJson).put("4",platform.getString("brd")).put("5","").put("6",input.oaid).put("7","").put("8","").put("9",input.androidId).put("10","").put("11","").put("12",extra.toString()).put("13",input.sdkName).put("14",deviceType()).put("15",uptimeHistory).put("16",bootHistory);
    JSONObject common=new JSONObject().put("appKey",input.appKey).put("sdkVersion","5.1.2.28-yw").put("appVersion",version).put("osVersion","Android "+Build.VERSION.RELEASE+",level "+Build.VERSION.SDK_INT).put("processName",process).put("network",network()).put("model",Build.MODEL);
    return new JSONObject().put("common",common).put("report",body);
  }
  private synchronized boolean cloneState(long installed)throws Exception {
    if(cloneState!=null)return cloneState;
    long oldInstall=history.getLong("installed",0),oldMarker=history.getLong("marker",0),current=marker.exists()?marker.lastModified():0;
    int anomaly=0;SharedPreferences.Editor editor=history.edit();if(oldInstall==0)editor.putLong("installed",installed);
    if(oldMarker==0){if(current!=0)anomaly=1;else{if(!marker.createNewFile()&&!marker.exists())throw new IllegalStateException("QIMEI install marker unavailable");editor.putLong("marker",marker.lastModified());}}
    else if(current==0)anomaly=2;else if(current<oldMarker)anomaly=3;else if(current>oldMarker)anomaly=4;
    if(anomaly>0){if(marker.exists()&&!marker.delete())throw new IllegalStateException("QIMEI install marker cannot be replaced");editor.remove("marker");}
    if(!editor.commit())throw new IllegalStateException("QIMEI install history unavailable");cloneState=oldInstall!=0&&installed>oldInstall&&anomaly>0;return cloneState;
  }
  private static List<String> split(String raw){List<String> values=new ArrayList<>();if(raw!=null)for(String value:raw.split(";"))if(!value.isEmpty())values.add(value);return values;}
  private static String version(PackageInfo info){String value=info.versionName;if(value==null||value.trim().isEmpty())return Integer.toString(info.versionCode);value=value.trim().replace('\n',' ').replace('\r',' ').replace("|","%7C");int dots=0;for(int i=0;i<value.length();i++)if(value.charAt(i)=='.')dots++;return dots<3?value+"."+info.versionCode:value;}
  private static String processName(Context context)throws Exception {if(Build.VERSION.SDK_INT>=28)return Application.getProcessName();byte[] raw=read("/proc/self/cmdline",4096);int count=0;while(count<raw.length&&raw[count]!=0)count++;return count==0?context.getPackageName():new String(raw,0,count,StandardCharsets.UTF_8);}
  private static byte[] read(String path,int limit)throws Exception {try(FileInputStream input=new FileInputStream(path);ByteArrayOutputStream output=new ByteArrayOutputStream()){byte[] data=new byte[1024];int count;while((count=input.read(data))!=-1){if(output.size()+count>limit)throw new IllegalStateException("QIMEI local metadata exceeds limit");output.write(data,0,count);}return output.toByteArray();}}
  private static String container(){try{String prefix="";File[] files=new File("/").listFiles();if(files!=null)for(File file:files){String name=file.getName();if(name.startsWith("init.")&&name.endsWith(".environment.rc")&&name.indexOf(".environment.rc")>5){prefix="1#"+name.substring(5,name.indexOf(".environment.rc"));break;}}String mounts=new String(read("/proc/self/mountinfo",2*1024*1024),StandardCharsets.UTF_8),kind="";if(mounts.contains("/lxc_container/"))kind="lxc";else{String cpuset=new String(read("/proc/self/cpuset",4096),StandardCharsets.UTF_8).trim();if(cpuset.contains("/docker")&&mounts.contains(cpuset))kind="docker";}return prefix+(kind.isEmpty()?"":"2#"+kind);}catch(Exception unavailable){return "";}}
  private static String firstIpv4(){try{Enumeration<NetworkInterface> interfaces=NetworkInterface.getNetworkInterfaces();while(interfaces!=null&&interfaces.hasMoreElements()){Enumeration<InetAddress> addresses=interfaces.nextElement().getInetAddresses();while(addresses.hasMoreElements()){InetAddress address=addresses.nextElement();if(!address.isLoopbackAddress()&&address instanceof Inet4Address)return address.getHostAddress();}}}catch(Exception unavailable){}return "0.0.0.0";}
  private static String multiUser(Context context){String[] parts=context.getFilesDir().getAbsolutePath().split("/");if(Build.VERSION.SDK_INT>=23){if(parts.length<5)return "0";try{Integer.parseInt(parts[3]);if(!"0".equals(parts[3]))return "1";}catch(NumberFormatException ignored){}return parts[4].equals(context.getPackageName())?"0":"2";}if(parts.length<4||parts[3].equals(context.getPackageName()))return "0";try{Integer.parseInt(parts[3]);return "0".equals(parts[3])?"2":"1";}catch(NumberFormatException ignored){return "2";}}
  @SuppressWarnings("deprecation") private String network(){try{ConnectivityManager cm=(ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);if(cm==null)return "unknown";String type="unknown";if(Build.VERSION.SDK_INT>=29){NetworkCapabilities caps=cm.getNetworkCapabilities(cm.getActiveNetwork());if(caps!=null){if(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))type="wifi";else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))type="mobile";else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))type="vpn";else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH))type="bluetooth";else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_LOWPAN))type="lowpan";else if(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE))type="wifi_aware";}}else{android.net.NetworkInfo info=cm.getActiveNetworkInfo();if(info!=null)switch(info.getType()){case 1:type="wifi";break;case 0:type="mobile";break;case 17:type="vpn";break;case 9:type="ethernet";break;case 6:type="wimax";break;case 7:type="bluetooth";break;default:break;}}if(!type.equals("mobile"))return type;TelephonyManager phone=(TelephonyManager)context.getSystemService(Context.TELEPHONY_SERVICE);if(phone==null)return "unknown";int kind=Build.VERSION.SDK_INT>=30?phone.getDataNetworkType():phone.getNetworkType();switch(kind){case 1:case 2:case 4:case 7:case 11:return "2G";case 3:case 5:case 6:case 8:case 9:case 10:case 12:case 14:case 15:return "3G";case 13:return "4G";case 20:return "5G";default:return "unknown";}}catch(Exception unavailable){return "unknown";}}
  private String deviceType(){try{UiModeManager manager=(UiModeManager)context.getSystemService(Context.UI_MODE_SERVICE);int mode=manager==null?0:manager.getCurrentModeType();if(mode==4||context.getPackageManager().hasSystemFeature("android.hardware.type.television")||context.getPackageManager().hasSystemFeature("android.software.leanback"))return "TV";switch(mode){case 6:return "WATCH";case 3:return "CAR";case 5:return "APPLIANCE";case 7:return "VR";default:return (context.getResources().getConfiguration().screenLayout&15)>=3?"Pad":"Phone";}}catch(Exception unavailable){return "Phone";}}
}
