#include "windows_cng.hpp"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace qimei::cng {
namespace {
void require(bool value){if(!value)throw std::runtime_error("Windows protocol crypto failed");}
void status(NTSTATUS value){require(value>=0);}
ULONG size(std::size_t value){require(value<=std::numeric_limits<ULONG>::max());return static_cast<ULONG>(value);}
struct Algorithm {
  BCRYPT_ALG_HANDLE handle=nullptr;
  explicit Algorithm(const wchar_t* name){status(BCryptOpenAlgorithmProvider(&handle,name,MS_PRIMITIVE_PROVIDER,0));}
  ~Algorithm(){if(handle)BCryptCloseAlgorithmProvider(handle,0);}
  Algorithm(const Algorithm&)=delete;Algorithm& operator=(const Algorithm&)=delete;
};
struct Key {BCRYPT_KEY_HANDLE handle=nullptr;~Key(){if(handle)BCryptDestroyKey(handle);}};
struct HashHandle {BCRYPT_HASH_HANDLE handle=nullptr;~HashHandle(){if(handle)BCryptDestroyHash(handle);}};
struct Secret {
  Bytes value;
  explicit Secret(std::size_t length):value(length){}
  explicit Secret(const Bytes& data):value(data){}
  ~Secret(){if(!value.empty())SecureZeroMemory(value.data(),value.size());}
};
ULONG property(BCRYPT_HANDLE object,const wchar_t* name){ULONG result=0,written=0;status(BCryptGetProperty(object,name,reinterpret_cast<PUCHAR>(&result),sizeof(result),&written,0));require(written==sizeof(result));return result;}
// CryptDecodeObjectEx may otherwise accept a valid prefix with trailing data.
void complete_der(const Bytes& der){
  require(der.size()>=2&&der.size()<=65536&&der[0]==0x30);std::size_t offset=2,length=der[1];
  if(length&128){const auto count=length&127;require(count>=1&&count<=4&&offset+count<=der.size()&&der[offset]!=0);length=0;for(std::size_t i=0;i<count;++i)length=(length<<8)|der[offset++];require(length>=128);}
  require(length==der.size()-offset);
}
}
Bytes digest(const Bytes& input,Hash method){
  Algorithm algorithm(method==Hash::md5?BCRYPT_MD5_ALGORITHM:BCRYPT_SHA256_ALGORITHM);
  Secret object(property(algorithm.handle,BCRYPT_OBJECT_LENGTH));HashHandle hash;
  status(BCryptCreateHash(algorithm.handle,&hash.handle,object.value.data(),size(object.value.size()),nullptr,0,0));
  std::uint8_t empty=0;auto* data=input.empty()?&empty:const_cast<PUCHAR>(input.data());status(BCryptHashData(hash.handle,data,size(input.size()),0));
  Bytes out(property(algorithm.handle,BCRYPT_HASH_LENGTH));status(BCryptFinishHash(hash.handle,out.data(),size(out.size()),0));return out;
}
Bytes cbc(const Bytes& input,const Bytes& key,const Bytes& iv,Cipher cipher,bool encrypt){
  const auto block=cipher==Cipher::aes?16U:8U;
  require(iv.size()==block&&input.size()<=std::size_t(std::numeric_limits<ULONG>::max())-32);
  require(cipher==Cipher::aes?(key.size()==16||key.size()==32):key.size()==(cipher==Cipher::des?8U:24U));
  Algorithm algorithm(cipher==Cipher::aes?BCRYPT_AES_ALGORITHM:cipher==Cipher::des?BCRYPT_DES_ALGORITHM:BCRYPT_3DES_ALGORITHM);
  status(BCryptSetProperty(algorithm.handle,BCRYPT_CHAINING_MODE,reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_CBC)),sizeof(BCRYPT_CHAIN_MODE_CBC),0));
  require(property(algorithm.handle,BCRYPT_BLOCK_LENGTH)==block);
  Secret object(property(algorithm.handle,BCRYPT_OBJECT_LENGTH));Key handle;
  status(BCryptGenerateSymmetricKey(algorithm.handle,&handle.handle,object.value.data(),size(object.value.size()),const_cast<PUCHAR>(key.data()),size(key.size()),0));
  // Manual PKCS padding handles empty plaintext without relying on null-input
  // size-query behavior. All buffers supplied to CNG have explicit lengths.
  Secret data(input);
  if(encrypt){const auto pad=block-data.value.size()%block;data.value.insert(data.value.end(),pad,static_cast<std::uint8_t>(pad));}
  else require(!data.value.empty()&&data.value.size()%block==0);
  auto next_iv=iv;Bytes out(data.value.size());ULONG written=0;
  if(encrypt)status(BCryptEncrypt(handle.handle,data.value.data(),size(data.value.size()),nullptr,next_iv.data(),size(next_iv.size()),out.data(),size(out.size()),&written,0));
  else status(BCryptDecrypt(handle.handle,data.value.data(),size(data.value.size()),nullptr,next_iv.data(),size(next_iv.size()),out.data(),size(out.size()),&written,0));
  require(written==out.size());
  if(!encrypt){const auto pad=out.back();unsigned invalid=pad==0||pad>block;for(unsigned i=0;i<block;++i){const unsigned mask=0U-static_cast<unsigned>(i<pad);invalid|=(static_cast<unsigned>(out[out.size()-1-i])^pad)&mask;}require(invalid==0);out.resize(out.size()-pad);}
  return out;
}
Bytes rsa(const Bytes& input,const Bytes& der){
  complete_der(der);require(input.size()<=245);
  struct Decoded {CERT_PUBLIC_KEY_INFO* value=nullptr;~Decoded(){if(value)LocalFree(value);}} decoded;
  DWORD length=0;require(CryptDecodeObjectEx(X509_ASN_ENCODING,X509_PUBLIC_KEY_INFO,der.data(),size(der.size()),CRYPT_DECODE_ALLOC_FLAG|CRYPT_DECODE_NOCOPY_FLAG,nullptr,&decoded.value,&length)!=FALSE);
  require(decoded.value&&decoded.value->Algorithm.pszObjId&&std::strcmp(decoded.value->Algorithm.pszObjId,szOID_RSA_RSA)==0&&decoded.value->PublicKey.cUnusedBits==0);
  Key key;require(CryptImportPublicKeyInfoEx2(X509_ASN_ENCODING,decoded.value,0,nullptr,&key.handle)!=FALSE);require(property(key.handle,BCRYPT_KEY_LENGTH)==2048);
  std::uint8_t empty=0;auto* source=input.empty()?&empty:const_cast<PUCHAR>(input.data());Bytes out(256);ULONG written=0;
  status(BCryptEncrypt(key.handle,source,size(input.size()),nullptr,nullptr,0,out.data(),size(out.size()),&written,BCRYPT_PAD_PKCS1));require(written==256);return out;
}
void random(std::uint8_t* output,std::size_t length){if(!length)return;require(output!=nullptr);status(BCryptGenRandom(nullptr,output,size(length),BCRYPT_USE_SYSTEM_PREFERRED_RNG));}
}
