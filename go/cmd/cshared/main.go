// Command tsnetbridge-cshared wraps the tsnetbridge package for c-shared
// builds, exporting C-callable functions for the HarmonyOS NAPI bridge.
//
// Build (OpenHarmony NDK):
//
//	CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
//	  CC=<ohos-ndk>/llvm/bin/aarch64-unknown-linux-ohos-clang \
//	  go build -buildmode=c-shared -o libtsnetbridge.so .
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"unsafe"

	"github.com/tslsb/tsnet-bridge/tsnetbridge"
)

// cStrCopy copies a Go string into a newly allocated C string.
// Caller must free it with C.free.
func cStrCopy(s string) *C.char {
	return C.CString(s)
}

//export Start
func Start(authKey *C.char, stateDir *C.char, hostname *C.char) C.int {
	return C.int(tsnetbridge.Start(C.GoString(authKey), C.GoString(stateDir), C.GoString(hostname)))
}

//export StartAsync
func StartAsync(authKey *C.char, stateDir *C.char, hostname *C.char) C.int {
	return C.int(tsnetbridge.StartAsync(C.GoString(authKey), C.GoString(stateDir), C.GoString(hostname)))
}

//export StartState
func StartState() *C.char {
	return cStrCopy(tsnetbridge.StartState())
}

//export SetInterfaces
func SetInterfaces(specsJSON *C.char) C.int {
	return C.int(tsnetbridge.SetInterfaces(C.GoString(specsJSON)))
}

// LastError returns the message from the most recent failed Start, or "".
// The host app surfaces this to the UI/logs because the sandboxed state
// directory where bridge-error.txt is written is not readable over adb/hdc.
//
//export LastError
func LastError() *C.char {
	return cStrCopy(tsnetbridge.LastError())
}

//export GetSelfInfo
func GetSelfInfo() *C.char {
	return cStrCopy(tsnetbridge.GetSelfInfo())
}

//export GetPeers
func GetPeers() *C.char {
	return cStrCopy(tsnetbridge.GetPeers())
}

//export Dial
func Dial(network *C.char, addr *C.char) *C.char {
	return cStrCopy(tsnetbridge.Dial(C.GoString(network), C.GoString(addr)))
}

//export Listen
func Listen(network *C.char, addr *C.char) *C.char {
	return cStrCopy(tsnetbridge.Listen(C.GoString(network), C.GoString(addr)))
}

//export Accept
func Accept(handle C.longlong) *C.char {
	return cStrCopy(tsnetbridge.Accept(int64(handle)))
}

// AcceptStart launches a background Accept and returns immediately.
//
//export AcceptStart
func AcceptStart(handle C.longlong) C.int {
	return C.int(tsnetbridge.AcceptStart(int64(handle)))
}

// AcceptPoll pops one accepted connection: {"handle":N|0} or {"error":"..."}.
//
//export AcceptPoll
func AcceptPoll(handle C.longlong) *C.char {
	return cStrCopy(tsnetbridge.AcceptPoll(int64(handle)))
}

// ForwardTCP exposes target ("host:port") on 127.0.0.1 through Tailscale.
// Returns {"handle":N,"port":P} or {"error":"..."}.
//
//export ForwardTCP
func ForwardTCP(localPort C.int, target *C.char) *C.char {
	return cStrCopy(tsnetbridge.ForwardTCP(int(localPort), C.GoString(target)))
}

//export CloseForward
func CloseForward(handle C.longlong) C.int {
	return C.int(tsnetbridge.CloseForward(int64(handle)))
}

//export Read
func Read(handle C.longlong, maxLen C.int) *C.char {
	// Returns JSON: {"data":"<base64>","err":"<msg>"}
	data, err := tsnetbridge.Read(int64(handle), int(maxLen))
	errStr := ""
	if err != nil {
		errStr = err.Error()
	}
	payload := map[string]interface{}{
		"data": base64.StdEncoding.EncodeToString(data),
		"err":  errStr,
	}
	b, _ := json.Marshal(payload)
	return cStrCopy(string(b))
}

//export Write
func Write(handle C.longlong, data *C.char, len C.int) C.int {
	goData := C.GoBytes(unsafe.Pointer(data), len)
	n, err := tsnetbridge.Write(int64(handle), goData)
	if err != nil {
		return -1
	}
	return C.int(n)
}

//export CloseConn
func CloseConn(handle C.longlong) C.int {
	return C.int(tsnetbridge.CloseConn(int64(handle)))
}

//export CloseListener
func CloseListener(handle C.longlong) C.int {
	return C.int(tsnetbridge.CloseListener(int64(handle)))
}

//export Close
func Close() C.int {
	return C.int(tsnetbridge.Close())
}

//export IsStarted
func IsStarted() C.int {
	if tsnetbridge.IsStarted() {
		return 1
	}
	return 0
}

//export FreeString
func FreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

func main() {}
