package org.unr.research.qimeiclient;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

/** Reads the installed APK's own signing-block / ZIP-comment channel metadata. */
public final class ApkChannel {
  private ApkChannel() {}
  public static String read(File apk)throws Exception {
    try(RandomAccessFile input=new RandomAccessFile(apk,"r")) {
      long length=input.length();if(length<22)return "";
      int tailSize=(int)Math.min(length,65535L+22);byte[] tail=new byte[tailSize];input.seek(length-tailSize);input.readFully(tail);ByteBuffer end=ByteBuffer.wrap(tail).order(ByteOrder.LITTLE_ENDIAN);
      int position=-1;for(int i=tailSize-22;i>=0;i--)if(end.getInt(i)==0x06054b50&&(end.getShort(i+20)&65535)==tailSize-i-22){position=i;break;}
      if(position<0)return "";long eocd=length-tailSize+position,central=end.getInt(position+16)&0xffffffffL,size=end.getInt(position+12)&0xffffffffL;
      if(central>=eocd||central+size!=eocd)return "";
      if(eocd>=20){input.seek(eocd-20);if(Integer.reverseBytes(input.readInt())==0x07064b50)return "";}
      byte[] payload=null;
      if(central>=24) {
        byte[] footer=new byte[24];input.seek(central-24);input.readFully(footer);ByteBuffer blockEnd=ByteBuffer.wrap(footer).order(ByteOrder.LITTLE_ENDIAN);
        if(blockEnd.getLong(8)==2334950737559900225L&&blockEnd.getLong(16)==3617552046287187010L) {
          long blockSize=blockEnd.getLong(0);
          if(blockSize>8*1024*1024)throw new IllegalStateException("QIMEI APK channel metadata exceeds limit");
          if(blockSize>=24&&central>=blockSize+8) {
            byte[] data=new byte[(int)blockSize+8];input.seek(central-blockSize-8);input.readFully(data);ByteBuffer entries=ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
            if(entries.getLong()==blockSize) {
              int limit=data.length-24;boolean signed=false;byte[] candidate=null;
              while(entries.position()<limit-8) {
                long count=entries.getLong();if(count<4||count>Integer.MAX_VALUE||count>limit-entries.position())break;
                int next=entries.position()+(int)count,id=entries.getInt();
                if(id==1896449818||id==-262969152)signed=true;
                else if(id==1903261812){candidate=new byte[(int)count-4];entries.get(candidate);}
                if(signed&&candidate!=null)break;entries.position(next);
              }
              if(signed)payload=candidate;
            }
          }
        }
      }
      if(payload==null){int comment=end.getShort(position+20)&65535;if(comment>0){payload=new byte[comment];System.arraycopy(tail,position+22,payload,0,comment);}}
      if(payload==null||payload.length<=4)return "";ByteBuffer metadata=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);int tag=metadata.getShort()&65535;short bytes=metadata.getShort();
      if(tag!=0x96fa||bytes<0||bytes>metadata.remaining())return "";
      Properties properties=new Properties();properties.load(new InputStreamReader(new ByteArrayInputStream(payload,4,bytes),StandardCharsets.UTF_8));return properties.getProperty("channelId");
    }
  }
}
