cmake_minimum_required(VERSION 3.16)
project(tsnapi)

set(CMAKE_CXX_STANDARD 17)

# Path to the Go c-shared output (libtsnetbridge.so). This is only used to
# report whether Tailscale support is bundled with the HAP; the library itself
# is resolved at runtime by napi_bridge.cpp via dlopen.
set(GO_SO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../go/cmd/cshared/out"
    CACHE PATH "Directory containing libtsnetbridge.so built from Go")

set(GO_SO "${GO_SO_DIR}/libtsnetbridge.so")

# The Go c-shared library is built with GOOS=android. That is the only Go build
# that keeps the current-goroutine pointer in a pthread key slot discovered at
# run time (runtime/cgo/gcc_android.c inittls) instead of in ELF TLS, and
# OpenHarmony's musl refuses ELF TLS relocations in a dlopen'd library. With the
# android build the library has no TLS relocations at all, so napi_bridge.cpp
# can dlopen it directly and degrade to failure sentinels (Direct LAN Mode) only
# if loading fails for some other reason.
if(EXISTS "${GO_SO}")
    message(STATUS "Found libtsnetbridge.so at ${GO_SO} — it will be packaged and loaded at runtime")
else()
    message(STATUS "libtsnetbridge.so NOT found at ${GO_SO} — Tailscale will be unavailable")
endif()

add_library(tsnapi SHARED napi_bridge.cpp video_decoder.cpp)
target_include_directories(tsnapi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Copying the Go library explicitly matters: the build directory keeps whatever
# was copied into it last time, so without this step an old library keeps being
# shipped in the HAP even after go/build produces a new one.
if(EXISTS "${GO_SO}")
    add_custom_command(TARGET tsnapi POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${GO_SO}" "$<TARGET_FILE_DIR:tsnapi>/libtsnetbridge.so"
        COMMENT "Copying libtsnetbridge.so next to libtsnapi.so")
endif()

# liblog.so stand-in: a Go library built for android always links against -llog,
# which OpenHarmony does not provide. Forwards to hilog.
add_library(log SHARED logstub.cpp)
target_include_directories(log PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/shim)
target_link_libraries(log PUBLIC libhilog_ndk.z.so)

# Link the OpenHarmony NAPI library shipped with the SDK.
target_link_libraries(tsnapi PUBLIC libace_napi.z.so)
# hilog, used to report why the Go library could not be loaded.
target_link_libraries(tsnapi PUBLIC libhilog_ndk.z.so)
# OH_Ability_StartNativeChildProcess, used by the tsnet child-process probe.
target_link_libraries(tsnapi PUBLIC libchild_process.so)
# video_decoder.cpp: surface-mode H.264 decode (scrcpy mirror).
target_link_libraries(tsnapi PUBLIC libnative_media_core.so libnative_media_vdec.so
        libnative_media_codecbase.so libnative_window.so)

# Diagnostic library loaded inside a native child process. It dlopens the Go
# library where the main app process cannot, to decide whether Tailscale can be
# embedded as a child process instead of in-process.
add_library(tsnetprobe SHARED tsnetprobe.cpp)
# Required by the official native-child-process guide for the child library.
target_link_libraries(tsnetprobe PUBLIC libhilog_ndk.z.so libchild_process.so)

# Control experiment: a 4-byte initial-exec thread-local variable. dlopening it
# from the app tells us whether musl rejects initial-exec TLS in dynamically
# loaded modules in general, or only for the much larger Go runtime.
add_library(tlsprobe SHARED tlsprobe.cpp)
# The toolchain defaults to emulated TLS (__emutls_v.*), which never produces a
# TLS segment; -fno-emulated-tls forces a real thread-local variable so the
# initial-exec model emits the same R_AARCH64_TLS_TPREL64 relocation the Go
# library has.
target_compile_options(tlsprobe PRIVATE -fno-emulated-tls -ftls-model=initial-exec)

# Screen-mirror native stack, ported from LambdaYH/ScrcpyForHarmonyOS
# (GPL-3.0): ADB over TLS (CNXN -> CMD_STLS upgrade), wireless-debugging
# pairing (SPAKE2 + 6-digit code), scrcpy stream transport, OH media
# decoders and the control channel. Ships as libscrcpy_native.so and is
# imported from ArkTS as 'libscrcpy_native.so'.
add_subdirectory(scrcpy)
