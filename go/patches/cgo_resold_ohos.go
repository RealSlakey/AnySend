// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build cgo && !netgo && (android || freebsd || dragonfly || openbsd)

package net

/*
#include <sys/types.h>
#include <sys/socket.h>

#include <netdb.h>
*/
import "C"

import "unsafe"

// OpenHarmony override of net/cgo_resold.go.
//
// The upstream file casts the buffer length to C.size_t because bionic, FreeBSD
// and the other BSDs declare getnameinfo's hostlen parameter as size_t.
// OpenHarmony's musl-based sysroot declares it as socklen_t, exactly like glibc,
// so the upstream cast does not compile. Only the cast differs; everything else,
// including the build tags that keep this file exclusive to those platforms, is
// unchanged. It is applied with go build -overlay so the Go toolchain on the
// machine stays untouched.
func cgoNameinfoPTR(b []byte, sa *C.struct_sockaddr, salen C.socklen_t) (int, error) {
	gerrno, err := C.getnameinfo(sa, salen, (*C.char)(unsafe.Pointer(&b[0])), C.socklen_t(len(b)), nil, 0, C.NI_NAMEREQD)
	return int(gerrno), err
}
