/*
 * tsnetprobe.cpp - Native child process entry point.
 *
 * This is a throwaway diagnostic: it runs in a freshly created native child
 * process (see OH_Ability_StartNativeChildProcess) and tries to dlopen the Go
 * c-shared library. In the main app process that dlopen fails because musl
 * refuses an initial-exec TLS relocation whose definition lives in a
 * dynamically loaded module ("initial-exec TLS resolves to dynamic definition
 * in libtsnetbridge.so"). A fresh process has an untouched static TLS area, so
 * this decides whether the Go library can live in a child process instead.
 *
 * It reports through hilog and also writes the same lines to the file named by
 * entryParams ("<outPath>|<absolute libtsnetbridge.so path>") so the parent can
 * read the verdict back without depending on hilog capture.
 */
#include "AbilityKit/native_child_process.h"

#include <hilog/log.h>
#include <dlfcn.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>

#define PROBE_TAG "tsnetprobe"
#define PROBE_DOMAIN 0xD003301

static std::string g_report;

static void report(const std::string& line) {
    OH_LOG_Print(LOG_APP, LOG_INFO, PROBE_DOMAIN, PROBE_TAG, "%{public}s", line.c_str());
    g_report += line;
    g_report += "\n";
}

static void reportf(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    report(buf);
}

static void tryLoad(const char* what, const char* name, void** outHandle) {
    if (*outHandle != nullptr) {
        return;
    }
    void* h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (h != nullptr) {
        *outHandle = h;
        reportf("dlopen(%s) OK: %s", what, name);
        return;
    }
    const char* err = dlerror();
    reportf("dlopen(%s) FAILED: %s", what, err != nullptr ? err : "(no dlerror)");
}

extern "C" __attribute__((visibility("default"))) void Main(NativeChildProcess_Args args) {
    report("child process started");
    reportf("pid report, entryParams=%s",
            args.entryParams != nullptr ? args.entryParams : "(null)");

    std::string params = args.entryParams != nullptr ? args.entryParams : "";
    const size_t sep = params.find('|');
    const std::string outPath = sep == std::string::npos ? std::string() : params.substr(0, sep);
    const std::string bridgePath = sep == std::string::npos ? std::string() : params.substr(sep + 1);

    void* handle = nullptr;
    if (!bridgePath.empty()) {
        tryLoad("absolute path", bridgePath.c_str(), &handle);
    }
    tryLoad("by name", "libtsnetbridge.so", &handle);

    if (handle != nullptr) {
        void* start = dlsym(handle, "Start");
        void* isStarted = dlsym(handle, "IsStarted");
        void* getSelfInfo = dlsym(handle, "GetSelfInfo");
        reportf("dlsym Start=%p IsStarted=%p GetSelfInfo=%p", start, isStarted, getSelfInfo);
        report("RESULT: Go library IS loadable in child process");
    } else {
        report("RESULT: Go library could NOT be loaded in child process");
    }

    if (!outPath.empty()) {
        FILE* f = fopen(outPath.c_str(), "w");
        if (f != nullptr) {
            fwrite(g_report.data(), 1, g_report.size(), f);
            fclose(f);
        }
    }
}
