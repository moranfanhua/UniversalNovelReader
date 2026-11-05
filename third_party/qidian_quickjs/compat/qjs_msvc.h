#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <intrin.h>
#include <malloc.h>
#include <BaseTsd.h>
#define __attribute__(x)
#define __attribute(x)
#define __builtin_expect(x,y) (x)
#define __builtin_frame_address(x) _AddressOfReturnAddress()
#define alloca _alloca
#define strdup _strdup
#define __thread __declspec(thread)
typedef SSIZE_T ssize_t;
static inline int __builtin_clz(unsigned x) {unsigned long i;_BitScanReverse(&i,x);return 31-(int)i;}
static inline int __builtin_ctz(unsigned x) {unsigned long i;_BitScanForward(&i,x);return (int)i;}
static inline int __builtin_clzll(uint64_t x) {unsigned long i;_BitScanReverse64(&i,x);return 63-(int)i;}
static inline int __builtin_ctzll(uint64_t x) {unsigned long i;_BitScanForward64(&i,x);return (int)i;}
