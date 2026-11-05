package org.unr.research.qimeiclient;

import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.X509EncodedKeySpec;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Android system primitives, independent of OStar and other proprietary SDKs. */
public final class SystemCrypto {
  private static final SecureRandom ENTROPY = new SecureRandom();
  private SystemCrypto() {}
  public static byte[] digest(int method, byte[] input) throws Exception {
    if (method != 0 && method != 1) throw new IllegalArgumentException("Unsupported digest");
    return MessageDigest.getInstance(method == 0 ? "MD5" : "SHA-256").digest(input);
  }
  public static byte[] cbc(boolean encrypt, byte[] input, byte[] key, byte[] iv) throws Exception {
    if (key.length != 16 || iv.length != 16) throw new IllegalArgumentException("Invalid AES size");
    Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
    cipher.init(encrypt ? Cipher.ENCRYPT_MODE : Cipher.DECRYPT_MODE, new SecretKeySpec(key,"AES"), new IvParameterSpec(iv));
    return cipher.doFinal(input);
  }
  public static byte[] rsa(byte[] input, byte[] der) throws Exception {
    RSAPublicKey key = (RSAPublicKey) KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(der));
    if (key.getModulus().bitLength() != 2048) throw new IllegalArgumentException("Invalid RSA size");
    Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
    cipher.init(Cipher.ENCRYPT_MODE, key, ENTROPY);
    return cipher.doFinal(input);
  }
  public static byte[] encrypt(int kind,byte[] input,byte[] key,byte[] iv)throws Exception {
    String name=kind==0?"DES":kind==1?"DESede":kind==2?"AES":null;
    if(name==null)throw new IllegalArgumentException("Unsupported cipher");
    Cipher cipher=Cipher.getInstance(name+"/CBC/PKCS5Padding");
    cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,name),new IvParameterSpec(iv));
    return cipher.doFinal(input);
  }
  public static byte[] random(int length) {
    if (length < 0 || length > 1024 * 1024) throw new IllegalArgumentException("Invalid entropy length");
    byte[] output = new byte[length]; ENTROPY.nextBytes(output); return output;
  }
}
