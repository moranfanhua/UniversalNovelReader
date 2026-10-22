#ifndef UNR_CHAPTER_CRYPTO_H
#define UNR_CHAPTER_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define UNR_CRYPTO_EXPORT __declspec(dllexport)
#else
#define UNR_CRYPTO_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const uint8_t* data;
  size_t length;
} UnrChapterBytes;

typedef struct {
  UnrChapterBytes data;
  UnrChapterBytes key;
  UnrChapterBytes iv;
  // 1: AES-CBC, 2: 3DES-CBC, 3: AES-CTR. CBC optionally removes PKCS#7.
  int32_t cipher;
  int32_t padding;
} UnrChapterDecryptInput;

typedef struct {
  uint8_t* data;
  size_t length;
  // 0: success, 1: invalid ciphertext/parameters/padding, 2: allocation
  // failure.
  int32_t status;
} UnrChapterDecryptOutput;

// Inputs are borrowed only during this synchronous call. Every output is
// initialized, and each job fails independently. No exception crosses the ABI.
UNR_CRYPTO_EXPORT int32_t
unr_chapter_decrypt_batch(const UnrChapterDecryptInput* inputs,
                          UnrChapterDecryptOutput* outputs, size_t count);
// Wipes the plaintext before releasing a successful result. NULL is accepted.
UNR_CRYPTO_EXPORT void unr_chapter_crypto_free(uint8_t* data, size_t length);

#ifdef __cplusplus
}
#endif
#endif
