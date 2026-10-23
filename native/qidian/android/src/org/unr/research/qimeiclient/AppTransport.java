package org.unr.research.qimeiclient;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.CookieHandler;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Timer;
import java.util.TimerTask;
import java.util.zip.GZIPInputStream;
import org.json.JSONObject;

/** One fixed App API POST, fixed streaming body, no application retries. */
public final class AppTransport implements AndroidQimeiClient.Wire {
  private static final String PATH="/argus/api/v1/client/ostar";
  private final URL endpoint;
  private HttpURLConnection active;
  private boolean closed;
  private int attempts,status,responseBytes;
  public AppTransport() throws Exception { endpoint=new URL("https://druidv6.if.qidian.com"+PATH); }
  private AppTransport(int port) throws Exception {
    if(port<1||port>65535)throw new IllegalArgumentException("Invalid loopback port");
    endpoint=new URL("http://127.0.0.1:"+port+PATH);
  }
  static AppTransport loopbackForTest(int port)throws Exception{return new AppTransport(port);}
  public synchronized int attempts(){return attempts;}
  public synchronized int status(){return status;}
  public synchronized int responseBytes(){return responseBytes;}
  public String exchange(String form,String[] names,String[] values)throws Exception {
    if(CookieHandler.getDefault()!=null)throw new IllegalStateException("External cookie handler unsupported");
    if(form==null||names==null||values==null||names.length!=values.length)throw new IllegalArgumentException("Incomplete request");
    byte[] body=form.getBytes(StandardCharsets.UTF_8);
    if(body.length>4*1024*1024)throw new IllegalArgumentException("Request too large");
    HttpURLConnection connection=(HttpURLConnection)endpoint.openConnection();
    synchronized(this){if(closed||active!=null)throw new IllegalStateException("Transport unavailable");active=connection;status=0;responseBytes=0;}
    Timer watchdog=new Timer("UNR QIMEI deadline",true);
    TimerTask deadline=new TimerTask(){@Override public void run(){connection.disconnect();}};
    try {
      connection.setInstanceFollowRedirects(false);connection.setUseCaches(false);connection.setConnectTimeout(10000);connection.setReadTimeout(30000);
      connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setFixedLengthStreamingMode(body.length);
      connection.setRequestProperty("Content-Type","application/x-www-form-urlencoded");connection.setRequestProperty("Accept-Encoding","gzip");connection.setRequestProperty("Connection","close");
      for(int i=0;i<names.length;i++){
        if(names[i]==null||names[i].isEmpty()||values[i]==null||!names[i].matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+"))throw new IllegalArgumentException("Invalid request header");
        for(int n=0;n<values[i].length();n++)if(values[i].charAt(n)<32||values[i].charAt(n)>126)throw new IllegalArgumentException("Invalid header value");
        connection.setRequestProperty(names[i],values[i]);
      }
      watchdog.schedule(deadline,45000);
      synchronized(this){if(closed)throw new IllegalStateException("Transport closed");attempts++;}
      try(OutputStream output=connection.getOutputStream()){output.write(body);}
      int code=connection.getResponseCode();synchronized(this){status=code;}
      InputStream raw=code>=400?connection.getErrorStream():connection.getInputStream();
      String encoding=connection.getHeaderField("Content-Encoding");
      if(encoding!=null&&!encoding.isEmpty()&&!encoding.equalsIgnoreCase("identity")&&!encoding.equalsIgnoreCase("gzip"))throw new IllegalStateException("Unsupported response encoding");
      ByteArrayOutputStream result=new ByteArrayOutputStream();
      if(raw!=null)try(InputStream input="gzip".equalsIgnoreCase(encoding)?new GZIPInputStream(raw):raw){
        byte[] buffer=new byte[8192];int count;
        while((count=input.read(buffer))!=-1){if(result.size()+count>1024*1024)throw new IllegalStateException("Response too large");result.write(buffer,0,count);}
      }
      synchronized(this){if(closed)throw new IllegalStateException("Transport closed");responseBytes=result.size();}
      return new JSONObject().put("httpStatus",code).put("body",new String(result.toByteArray(),StandardCharsets.UTF_8)).toString();
    } finally {
      deadline.cancel();watchdog.cancel();connection.disconnect();synchronized(this){if(active==connection)active=null;}
    }
  }
  @Override public void close(){HttpURLConnection connection;synchronized(this){closed=true;connection=active;}if(connection!=null)connection.disconnect();}
}
