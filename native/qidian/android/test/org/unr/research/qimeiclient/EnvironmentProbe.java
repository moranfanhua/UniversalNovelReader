package org.unr.research.qimeiclient;

import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.zip.CRC32;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONArray;
import org.json.JSONObject;

/** Offline instrumentation fixture; its manifest must not grant INTERNET. */
public final class EnvironmentProbe extends Instrumentation {
  private int checks;
  private int requests;
  private String failedCheck = "";

  private void check(String name, boolean value) {
    checks++;
    if (!value) {
      failedCheck = name;
      throw new AssertionError(name);
    }
  }

  @Override public void onCreate(Bundle arguments) {
    super.onCreate(arguments);
    start();
  }

  private static String encoded(String value) {
    return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
  }

  private static byte[] decrypt(byte[] input, byte[] material, boolean des) throws Exception {
    String algorithm = des ? "DES" : "AES";
    Cipher cipher = Cipher.getInstance(algorithm + "/CBC/PKCS5Padding");
    cipher.init(Cipher.DECRYPT_MODE,
        new SecretKeySpec(Arrays.copyOf(material, des ? 8 : 32), algorithm),
        new IvParameterSpec(Arrays.copyOf(material, des ? 8 : 16)));
    return cipher.doFinal(input);
  }

  private static String plaintext(String token) throws Exception {
    byte[] encoded = Base64.decode(token, Base64.URL_SAFE | Base64.NO_WRAP);
    byte[] material = Arrays.copyOfRange(encoded, encoded.length - 32, encoded.length);
    byte[] body = Arrays.copyOf(encoded, encoded.length - 32);
    CRC32 crc = new CRC32();
    crc.update(material);
    body = decrypt(body, material, ((crc.getValue() >> 4) & 1) != 0);
    body = decrypt(body, material, (crc.getValue() & 1) != 0);
    return new String(body, StandardCharsets.UTF_8);
  }

  @Override public void onStart() {
    Bundle output = new Bundle();
    try {
      Context context = getTargetContext();
      check("debuggable-fixture", (context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0);
      check("no-internet-permission", context.checkCallingOrSelfPermission("android.permission.INTERNET") != 0);
      String filename = "test-environment-" + Long.toHexString(System.nanoTime()) + ".json";
      File directory = new File(context.getFilesDir(), "unr-qimei-client-v1");
      check("private-directory", directory.isDirectory() || directory.mkdirs());
      File cache = new File(directory, filename);
      byte[] saved = new JSONObject().put("version", 1)
          .put("appKey", encoded("0I000JZU8B16UN21"))
          .put("qimei", encoded("synthetic-qimei16")).put("qimei36", "")
          .put("riskUntilMs", "0").toString().getBytes(StandardCharsets.UTF_8);
      try (FileOutputStream stream = new FileOutputStream(cache)) {
        stream.write(saved);
      }
      AndroidQimeiClient.Wire offline = new AndroidQimeiClient.Wire() {
        @Override public String exchange(String form, String[] names, String[] values) {
          requests++;
          throw new AssertionError("Unexpected transport");
        }
        @Override public void close() {}
      };
      try (AndroidQimeiClient client = new AndroidQimeiClient(context,
          AndroidQimeiClient.Session.anonymous(), true, offline, null, filename)) {
        Field field = AndroidQimeiClient.class.getDeclaredField("handle");
        field.setAccessible(true);
        long handle = field.getLong(client);
        JSONObject inputs = new JSONObject().put("guid", "").put("qimei", "")
            .put("qimei36", "").put("model", Build.MODEL).put("ssid", JSONObject.NULL)
            .put("interfaces", new JSONArray())
            .put("packages", new JSONArray().put("com.topjohnwu.magisk"));
        JSONObject options = new JSONObject().put("settings",
            new JSONObject().put("suspiciousDylibs", "libqimei_client_android.so"));
        for (boolean legacyInputs : new boolean[] {false, true}) {
          if (legacyInputs) inputs.put("accessibilityEnabled", 1)
              .put("services", "fixture/AccessibilityService:autojs");
          JSONObject report = NativeClient.collectReport(handle, context, inputs, options);
          for (String key : new String[] {"obs_isDebug", "obs_isCheckZygiskByMap",
              "obs_isRootByPath", "obs_isRootByPackageName", "obs_isRootByMagisk",
              "obs_isRootByAttr", "obs_isAccessibilityEnable", "obs_isAutoJsByAccessibility"}) {
            check("fixed-" + key, report.has(key) && !report.getBoolean(key));
          }
          check("empty-module-names", report.getString("obs_hasSuspiciousDylib").isEmpty());
          check("empty-loaded-library", report.getString("obs_loadLib").isEmpty());
        }
        JSONObject ready = client.ensure(true, false);
        check("cached-provider-ready", ready.getBoolean("ready") && ready.getBoolean("fromCache"));
        JSONObject headers = client.headers(new JSONObject().put("BookId", "12"), new JSONObject());
        JSONObject environment = new JSONObject(plaintext(headers.getString("gorgon")));
        for (String key : new String[] {"debug", "root", "accessibility", "autojs"}) {
          check("wire-" + key, environment.getString(key).equals("0"));
        }
        check("wire-root-bit-clear", (Long.parseLong(environment.getString("env")) & 4L) == 0);
        String[] slots = plaintext(headers.getString("ibex")).split("\\|", -1);
        check("ibex-slot-count", slots.length == 64);
        check("ibex-root-accessibility", slots[23].equals("0") && slots[25].equals("0"));
        check("ibex-module-names", slots[59].isEmpty());
        check("cached-identifiers-preserved", slots[54].equals("synthetic-qimei16") && slots[55].isEmpty());
        check("private-cache-preserved", Arrays.equals(saved, Files.readAllBytes(cache.toPath())));
      }
      check("no-transport", requests == 0);
      output.putString("summary", new JSONObject().put("passed", true).put("checks", checks)
          .put("platformRequests", requests).put("debuggableFixture", true).toString());
    } catch (Throwable error) {
      output.putString("summary", "{\"passed\":false,\"checks\":" + checks
          + ",\"failedCheck\":\"" + failedCheck + "\",\"errorClass\":\""
          + error.getClass().getSimpleName() + "\"}");
    }
    finish(0, output);
  }
}
