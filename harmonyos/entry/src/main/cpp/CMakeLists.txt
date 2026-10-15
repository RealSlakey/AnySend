cmake_minimum_required(VERSION 3.16)
project(tsnapi)

set(CMAKE_CXX_STANDARD 17)

# Path to the Go c-shared output (libtsnetbridge.so + tsnetbridge.h)
set(GO_SO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../go/cmd/cshared/out"
    CACHE PATH "Directory containing libtsnetbridge.so built from Go")

set(GO_SO "${GO_SO_DIR}/libtsnetbridge.so")

# The tsnetbridge native library is optional. When absent (e.g. local dev
# without the OpenHarmony NDK toolchain), we compile napi_bridge.cpp with
# TSNETBRIDGE_STUB defined so it returns failure sentinels and the app
# falls back to Direct LAN Mode.
if(EXISTS "${GO_SO}")
    message(STATUS "Found libtsnetbridge.so at ${GO_SO} — building with Tailscale support")
    add_library(tsnetbridge SHARED IMPORTED)
    set_target_properties(tsnetbridge PROPERTIES
        IMPORTED_LOCATION "${GO_SO}"
        INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}")
    add_library(tsnapi SHARED napi_bridge.cpp)
    target_include_directories(tsnapi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(tsnapi tsnetbridge)
else()
    message(STATUS "libtsnetbridge.so NOT found at ${GO_SO} — building stub NAPI (Direct LAN Mode only)")
    add_library(tsnapi SHARED napi_bridge.cpp)
    target_include_directories(tsnapi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(tsnapi PRIVATE TSNETBRIDGE_STUB=1)
endif()

# Find NAPI headers from the OpenHarmony SDK
find_library(napi_lib NAMES napi)
if(napi_lib)
    target_link_libraries(tsnapi ${napi_lib})
endif()
