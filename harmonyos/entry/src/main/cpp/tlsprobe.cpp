/*
 * tlsprobe.cpp - minimal shared library that forces the initial-exec TLS
 * model.
 *
 * OpenHarmony's musl refuses to relocate the Go c-shared library because its
 * initial-exec TLS has "a dynamic definition" (the library is loaded with
 * dlopen, so its TLS block is allocated at load time rather than at process
 * start). This library reproduces the same condition in the smallest possible
 * way: a single thread-local int accessed through initial-exec. If musl accepts
 * this one but rejects the Go library, the difference is not the TLS model
 * itself - which tells us where to dig. If it rejects this one too, musl's
 * policy is unconditional and no amount of process isolation will help.
 */
__thread int tls_probe_counter = 0;

extern "C" int TlsProbeRead(void) {
    tls_probe_counter += 1;
    return tls_probe_counter;
}
