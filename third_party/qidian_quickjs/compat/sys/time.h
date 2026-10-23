#pragma once
#include <windows.h>

static inline int gettimeofday(struct timeval* tv, void* tz) {
 FILETIME t;ULARGE_INTEGER u;(void)tz;GetSystemTimeAsFileTime(&t);
 u.LowPart=t.dwLowDateTime;u.HighPart=t.dwHighDateTime;
 u.QuadPart-=116444736000000000ULL;
 tv->tv_sec=(long)(u.QuadPart/10000000);tv->tv_usec=(long)((u.QuadPart%10000000)/10);return 0;
}
