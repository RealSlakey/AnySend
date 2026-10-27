/*
 * liblog.so stand-in for OpenHarmony.
 *
 * A Go library built with GOOS=android always links against -llog, which on
 * Android is the system logger. OpenHarmony has no liblog.so, so this builds
 * one that forwards to hilog. It is packed into the HAP next to the Go library
 * so that the dynamic linker can resolve the dependency at load time.
 */
#include "android/log.h"

#include <hilog/log.h>
#include <cstdio>
#include <cstdlib>

#define LOGSTUB_TAG "liblog-stub"
#define LOGSTUB_DOMAIN 0xD003302

static void forward(const char* tag, const char* text) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOGSTUB_DOMAIN, LOGSTUB_TAG,
                 "[%{public}s] %{public}s", tag != nullptr ? tag : "?", text);
}

extern "C" int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap) {
    (void)prio;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    forward(tag, buf);
    return 0;
}

extern "C" int __android_log_print(int prio, const char* tag, const char* fmt, ...) {
    (void)prio;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    forward(tag, buf);
    return 0;
}

extern "C" int __android_log_write(int prio, const char* tag, const char* text) {
    (void)prio;
    forward(tag, text != nullptr ? text : "");
    return 0;
}

extern "C" void __android_log_assert(const char* cond, const char* tag, const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char line[1152];
    snprintf(line, sizeof(line), "assert(%s): %s", cond != nullptr ? cond : "", buf);
    forward(tag, line);
    abort();
}
