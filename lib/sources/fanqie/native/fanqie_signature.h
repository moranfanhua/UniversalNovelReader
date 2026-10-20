// Protocol port from ch6vip/fqapp (GPL-3.0), credited in README.md.
#ifndef UNR_FANQIE_SIGNATURE_H
#define UNR_FANQIE_SIGNATURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define UNR_EXPORT __declspec(dllexport)
#else
#define UNR_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const uint8_t* data;
  size_t length;
} UnrFanqieBytes;

typedef struct {
  UnrFanqieBytes query;
  UnrFanqieBytes body;
  UnrFanqieBytes aid;
  UnrFanqieBytes device;
  UnrFanqieBytes version;
  int64_t timestamp;
  uint32_t nonce;
} UnrFanqieArgusInput;

// Inputs are borrowed for the duration of the call. Returned UTF-8 strings
// belong to this library and must be released with unr_fanqie_signature_free.
// Failure returns NULL; exceptions never cross the C ABI.
UNR_EXPORT char* unr_fanqie_ladon(int64_t timestamp, int64_t aid,
                                  const uint8_t* random);
UNR_EXPORT char* unr_fanqie_argus(const UnrFanqieArgusInput* input);
UNR_EXPORT void unr_fanqie_signature_free(void* result);

// The block (16 bytes), key (32 bytes) and output (16 bytes) use little endian
// 64-bit words. Returns 0 on success, -1 for invalid pointers.
UNR_EXPORT int32_t unr_fanqie_simon(const uint8_t* block, const uint8_t* key,
                                    int32_t decrypt, uint8_t* output);

#ifdef __cplusplus
}
#endif
#endif
