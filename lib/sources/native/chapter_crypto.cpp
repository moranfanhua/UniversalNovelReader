#include "chapter_crypto.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>

#include "mbedtls/aes.h"
#include "mbedtls/des.h"
#include "mbedtls/platform_util.h"

namespace {
class AesContext {
 public:
  mbedtls_aes_context value;
  AesContext() { mbedtls_aes_init(&value); }
  ~AesContext() { mbedtls_aes_free(&value); }
};

class DesContext {
 public:
  mbedtls_des3_context value;
  DesContext() { mbedtls_des3_init(&value); }
  ~DesContext() { mbedtls_des3_free(&value); }
};

bool valid(const UnrChapterDecryptInput& input) {
  if ((input.data.length != 0 && input.data.data == nullptr) ||
      input.key.data == nullptr || input.iv.data == nullptr ||
      (input.padding != 0 && input.padding != 1))
    return false;
  if (input.cipher == 2) {
    if ((input.key.length != 16 && input.key.length != 24) ||
        input.iv.length != 8)
      return false;
  } else if (input.cipher == 1 || input.cipher == 3) {
    if ((input.key.length != 16 && input.key.length != 24 &&
         input.key.length != 32) ||
        input.iv.length != 16)
      return false;
  } else {
    return false;
  }
  if (input.cipher == 3) return input.padding == 0;
  const size_t block = input.cipher == 2 ? 8 : 16;
  return input.data.length != 0 && input.data.length % block == 0;
}

int decrypt(const UnrChapterDecryptInput& input, uint8_t* output) {
  std::array<uint8_t, 16> iv{};
  std::memcpy(iv.data(), input.iv.data, input.iv.length);
  if (input.cipher == 2) {
    DesContext context;
    const int status =
        input.key.length == 16
            ? mbedtls_des3_set2key_dec(&context.value, input.key.data)
            : mbedtls_des3_set3key_dec(&context.value, input.key.data);
    if (status != 0) return status;
    return mbedtls_des3_crypt_cbc(&context.value, MBEDTLS_DES_DECRYPT,
                                  input.data.length, iv.data(), input.data.data,
                                  output);
  }
  AesContext context;
  const auto bits = static_cast<unsigned>(input.key.length * 8);
  if (input.cipher == 3) {
    const int status =
        mbedtls_aes_setkey_enc(&context.value, input.key.data, bits);
    if (status != 0) return status;
    size_t offset = 0;
    std::array<uint8_t, 16> stream{};
    return mbedtls_aes_crypt_ctr(&context.value, input.data.length, &offset,
                                 iv.data(), stream.data(), input.data.data,
                                 output);
  }
  const int status =
      mbedtls_aes_setkey_dec(&context.value, input.key.data, bits);
  if (status != 0) return status;
  return mbedtls_aes_crypt_cbc(&context.value, MBEDTLS_AES_DECRYPT,
                               input.data.length, iv.data(), input.data.data,
                               output);
}

bool unpad(uint8_t* output, size_t& length, size_t block) {
  const auto count = output[length - 1];
  unsigned invalid = count == 0 || count > block;
  // Inspect the full last block, including when the padding length is invalid.
  for (size_t i = 1; i <= block; ++i) {
    invalid |= (i <= count ? 0xffu : 0u) & (output[length - i] ^ count);
  }
  if (invalid != 0) return false;
  length -= count;
  return true;
}
}  // namespace

extern "C" {
int32_t unr_chapter_decrypt_batch(const UnrChapterDecryptInput* inputs,
                                  UnrChapterDecryptOutput* outputs,
                                  size_t count) {
  if (count != 0 && (inputs == nullptr || outputs == nullptr)) return -1;
  for (size_t i = 0; i < count; ++i) {
    auto& result = outputs[i];
    result = {nullptr, 0, 1};
    const auto& input = inputs[i];
    if (!valid(input)) continue;
    auto* buffer = static_cast<uint8_t*>(
        std::malloc(std::max(input.data.length, size_t{1})));
    if (buffer == nullptr) {
      result.status = 2;
      continue;
    }
    size_t length = input.data.length;
    bool success = false;
    try {
      success = decrypt(input, buffer) == 0;
      if (success && input.padding != 0) {
        success = unpad(buffer, length, input.cipher == 2 ? 8 : 16);
      }
    } catch (...) {
      success = false;
    }
    if (success) {
      result = {buffer, length, 0};
    } else {
      unr_chapter_crypto_free(buffer, input.data.length);
    }
  }
  return 0;
}

void unr_chapter_crypto_free(uint8_t* data, size_t length) {
  if (data != nullptr) {
    mbedtls_platform_zeroize(data, length);
    std::free(data);
  }
}
}
