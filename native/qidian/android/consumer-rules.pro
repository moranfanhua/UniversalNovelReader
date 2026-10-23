# JNI callbacks are resolved by fixed class/method names. Retain these names
# when the calling application enables R8/ProGuard in release builds.
-keep class org.unr.research.qimeiclient.NativeClient { *; }
-keep class org.unr.research.qimeiclient.AndroidSnapshot { native <methods>; }
-keep class org.unr.research.qimeiclient.SystemCrypto { public static <methods>; }
-keepclassmembers class org.unr.research.qimeiclient.AndroidQimeiClient {
    private java.lang.String collectSnapshot(java.lang.String,java.lang.String);
    private java.lang.String exchange(java.lang.String,java.lang.String[],java.lang.String[]);
    private void cancelTransport();
}
