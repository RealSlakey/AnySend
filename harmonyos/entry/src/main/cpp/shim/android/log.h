/*
 * Minimal stand-in for Android's <android/log.h>.
 *
 * Go's c-shared runtime is built here with GOOS=android, because that is the
 * only platform where Go stores its current-goroutine pointer in a pthread key
 * slot discovered at run time instead of in ELF TLS (see runtime/cgo/
 * gcc_android.c, inittls, and runtime/tls_arm64.h's TLSG_IS_VARIABLE). An
 * OpenHarmony HAP cannot use ELF TLS in a dlopen'd library, so that android
 * build mode is the only one that can be loaded at run time.
 *
 * The OpenHarmony sysroot ships no Android headers, and compiling Go's
 * runtime/cgo needs exactly one function from this header - __android_log_vprint
 * (used by fatalf) - so this shim declares just that, plus the small set of
 * declarations the stub liblog.so implements.
 */
#ifndef TSNAPI_ANDROID_LOG_SHIM_H
#define TSNAPI_ANDROID_LOG_SHIM_H

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

enum android_LogPriority {
    ANDROID_LOG_UNKNOWN = 0,
    ANDROID_LOG_DEFAULT,
    ANDROID_LOG_VERBOSE,
    ANDROID_LOG_DEBUG,
    ANDROID_LOG_INFO,
    ANDROID_LOG_WARN,
    ANDROID_LOG_ERROR,
    ANDROID_LOG_FATAL,
    ANDROID_LOG_SILENT,
};

int __android_log_print(int prio, const char* tag, const char* fmt, ...);
int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap);
int __android_log_write(int prio, const char* tag, const char* text);
void __android_log_assert(const char* cond, const char* tag, const char* fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* TSNAPI_ANDROID_LOG_SHIM_H */
