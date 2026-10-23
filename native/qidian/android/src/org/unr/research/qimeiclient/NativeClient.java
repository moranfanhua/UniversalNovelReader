package org.unr.research.qimeiclient;
import android.content.Context;
import org.json.JSONObject;
final class NativeClient {
  static { System.loadLibrary("qimei_client_android"); }
  static native String profile();
  static native long create(Object owner,String privateFile,String profile,boolean consent);
  static native String ensure(long handle,boolean consent,boolean forceRefresh);
  static native String headers(long handle,String params,String session);
  static native String scripts(long handle,String command);
  static native boolean pause(long handle);
  static native void close(long handle);
  static native JSONObject collectReport(long handle,Context context,JSONObject inputs,JSONObject options);
  static native String property(String name);
}
