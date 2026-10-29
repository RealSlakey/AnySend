// Package tsnetbridge wraps Tailscale's tsnet library for embedding in
// Android (via gomobile AAR) and HarmonyOS NEXT (via c-shared .so + NAPI).
//
// It uses tsnet's built-in userspace netstack, so no TUN/VPN permission
// is required from the host OS.
package tsnetbridge

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/client/tailscale"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

// PeerInfo describes a single Tailscale peer on the same tailnet.
type PeerInfo struct {
	HostName    string `json:"hostName"`
	TailscaleIP string `json:"tailscaleIP"`
	Online      bool   `json:"online"`
}

// SelfInfo describes the local node after it comes online.
type SelfInfo struct {
	HostName    string `json:"hostName"`
	TailscaleIP string `json:"tailscaleIP"`
}

var (
	// mu guards server/local/started. Start() holds it for the entire tsnet
	// bring-up (tens of seconds), so nothing on the UI thread may ever take
	// it: the host polls StartState and a cgo call blocked on this lock would
	// freeze the UI thread past HarmonyOS's 6 s watchdog (THREAD_BLOCK_6S).
	mu      sync.Mutex
	server  *tsnet.Server
	local   *tailscale.LocalClient
	started bool

	// stateMu guards startPhase/lastErr only. Every access is a quick memory
	// read/write, so the UI-thread poll (StartState/LastError) never blocks
	// behind a running Start.
	stateMu sync.Mutex

	// startPhase tracks an async start: "" idle, "starting" in flight,
	// "running" or "failed" once StartAsync settles.
	startPhase string

	// lastErr holds the most recent startup error. Android redirects an app's
	// stderr to /dev/null, so the error is also persisted to disk (see
	// recordError) where it can be read back with `adb shell run-as`.
	lastErr string
)

// StartAsync kicks off Start on a background goroutine and returns
// immediately. The host's UI thread must never block on Start: on HarmonyOS
// the main-thread watchdog kills the process after 6 s of unresponsiveness
// (THREAD_BLOCK_6S), and tsnet's full start (DERP, control plane) can
// legitimately take longer. The host polls StartState.
func StartAsync(authKey, stateDir, hostname string) int {
	stateMu.Lock()
	if startPhase == "starting" {
		stateMu.Unlock()
		return 0
	}
	startPhase = "starting"
	stateMu.Unlock()
	writePhase(stateDir, "starting")

	mu.Lock()
	alreadyStarted := started
	mu.Unlock()
	if alreadyStarted {
		stateMu.Lock()
		startPhase = "running"
		stateMu.Unlock()
		writePhase(stateDir, "running")
		return 0
	}

	go func() {
		rc := Start(authKey, stateDir, hostname)
		phase := "failed"
		if rc == 0 {
			phase = "running"
		}
		stateMu.Lock()
		startPhase = phase
		stateMu.Unlock()
		writePhase(stateDir, phase)
	}()
	return 0
}

// StartState reports the async-start progress as JSON:
// {"phase":"idle|starting|running|failed","err":"..."}.
func StartState() string {
	stateMu.Lock()
	defer stateMu.Unlock()
	b, _ := json.Marshal(map[string]string{"phase": startPhase, "err": lastErr})
	return string(b)
}

// writePhase persists the async-start progress to dir/phase.json.
//
// The host's UI thread must not poll startPhase through cgo: while Start is
// running (heavy goroutine/M churn under srv.Start), an external cgo
// callback into the Go runtime can stall indefinitely on HarmonyOS, which
// trips the 6 s main-thread watchdog (THREAD_BLOCK_6S). The host instead
// watches this plain file with its own async file APIs.
func writePhase(dir, phase string) {
	if dir == "" {
		return
	}
	stateMu.Lock()
	errStr := lastErr
	stateMu.Unlock()
	b, _ := json.Marshal(map[string]string{"phase": phase, "err": errStr})
	_ = os.WriteFile(filepath.Join(dir, "phase.json"), b, 0o644)
}

// recordError stores err both in memory (exposed via LastError) and in
// dir/bridge-error.txt so it survives regardless of log routing.
func recordError(dir string, err error) {
	if err == nil {
		return
	}
	stateMu.Lock()
	lastErr = err.Error()
	stateMu.Unlock()
	if dir != "" {
		_ = os.WriteFile(filepath.Join(dir, "bridge-error.txt"),
			[]byte(err.Error()+"\n"), 0o644)
	}
	log.Printf("tsnetbridge: %v", err)
}

// LastError returns the message from the most recent failed Start call,
// or an empty string if the last start attempt succeeded.
func LastError() string {
	stateMu.Lock()
	defer stateMu.Unlock()
	return lastErr
}

// ifaceSpec is the JSON shape SetInterfaces accepts from the host app.
type ifaceSpec struct {
	Name  string   `json:"name"`
	Index int      `json:"index"`
	MTU   int      `json:"mtu"`
	Up    bool     `json:"up"`
	Addrs []string `json:"addrs"` // CIDR form, e.g. "192.168.5.108/24"
}

// SetInterfaces hands the host's network interfaces to Tailscale's netmon.
//
// Android SDK 30+ forbids binding a netlink socket, so Go's net.Interfaces()
// fails with "netlinkrib: permission denied" and aborts tsnet startup
// entirely (tailscale/tailscale#2293). netmon exposes RegisterInterfaceGetter
// for exactly this case; the host app enumerates interfaces through its own
// sanctioned API and passes them here.
//
// Addresses go into AltAddrs so that Interface.Addrs() doesn't fall back to
// netlink either.
//
// Returns 0 on success, 1 if specsJSON could not be parsed.
func SetInterfaces(specsJSON string) int {
	var specs []ifaceSpec
	if err := json.Unmarshal([]byte(specsJSON), &specs); err != nil {
		recordError("", fmt.Errorf("SetInterfaces: %w", err))
		return 1
	}

	ifaces := make([]netmon.Interface, 0, len(specs))
	for _, s := range specs {
		ni := &net.Interface{Name: s.Name, Index: s.Index, MTU: s.MTU}
		if s.Up {
			ni.Flags |= net.FlagUp | net.FlagRunning
		}
		var addrs []net.Addr
		for _, cidr := range s.Addrs {
			ip, ipnet, err := net.ParseCIDR(cidr)
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: ip, Mask: ipnet.Mask})
		}
		if len(addrs) > 0 {
			ni.Flags |= net.FlagUp
		}
		ifaces = append(ifaces, netmon.Interface{Interface: ni, AltAddrs: addrs})
	}

	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return ifaces, nil
	})
	hostInjected = true
	return 0
}

// hostInjected records whether SetInterfaces was called by the host app.
// Start calls ensureInterfaces when it was not, so the embedded node also
// works on hosts that have no sanctioned interface-enumeration API to call
// SetInterfaces with (HarmonyOS NEXT).
var hostInjected bool

// ensureInterfaces registers a fallback interface getter when the host has
// not injected one. HarmonyOS forbids the netlink route query Go's
// net.Interfaces() performs, exactly like Android 14 does, but unlike
// Android it exposes no public API to enumerate interfaces either. So derive
// the primary address with the UDP-connect trick (a pure routing decision,
// no packet is sent) and hand tsnet a synthetic "wlan0".
//
// The getter must be registered before tsnet.Server.Start, which is where
// the netlink query happens ("srv.Start: tsnet: route ip+net: netlinkrib:
// permission denied" otherwise).
func ensureInterfaces() {
	if hostInjected {
		return
	}
	ni := &net.Interface{
		Name:  "wlan0",
		Index: 1,
		MTU:   1500,
		// Running is what netmon.State uses to decide "some interface is up".
		Flags: net.FlagUp | net.FlagRunning | net.FlagBroadcast | net.FlagMulticast,
	}
	var addrs []net.Addr
	if ip := primaryAddrUDP(); ip != nil {
		addrs = append(addrs, &net.IPNet{IP: ip, Mask: net.CIDRMask(24, 32)})
	}
	ifaces := []netmon.Interface{{Interface: ni, AltAddrs: addrs}}
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return ifaces, nil
	})
	hostInjected = true
}

// primaryAddrUDP finds the source address the kernel would pick for a
// route to a public IP by "connecting" an unconnected UDP socket. connect()
// on a UDP socket only programs the destination and performs the route
// lookup; nothing is transmitted, so it works even with no listener behind
// the target and inside network sandboxes that block netlink.
func primaryAddrUDP() net.IP {
	// A public IPv4 target so the default route (not the tailnet's own
	// 100.64/10 range) is selected; port 53 is irrelevant, nothing is sent.
	c, err := net.DialTimeout("udp", "8.8.8.8:53", 3*time.Second)
	if err != nil {
		return nil
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).IP
}

// stderrFile holds the file fd 2 was redirected to. It must stay reachable:
// if it were garbage collected the descriptor would close and stderr with it.
var stderrFile *os.File

// redirectStderr points the process's stderr at dir/stderr.log.
//
// Go reports unrecovered panics and fatal runtime errors on stderr, and Android
// sends an app's stderr to /dev/null — a crash then leaves only a bare SIGABRT
// with no cause. This makes the actual message readable after the fact.
func redirectStderr(dir string) {
	if dir == "" || stderrFile != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(dir, "stderr.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	// arm64 has no dup2 syscall, only dup3.
	if err := unix.Dup3(int(f.Fd()), 2, 0); err != nil {
		f.Close()
		return
	}
	stderrFile = f
}

// Start brings up the embedded Tailscale node.
//
// authKey: a Tailscale auth key (reusable or one-off). Empty string falls back
//
//	to interactive login (the login URL is printed to logs).
//
// stateDir: directory used to persist node state. Must be writable.
//
// hostname: the name this node advertises to the tailnet.
//
// Returns 0 on success, non-zero on error.
func Start(authKey, stateDir, hostname string) int {
	mu.Lock()
	defer mu.Unlock()
	if started {
		return 0
	}

	redirectStderr(stateDir)

	// Must run before srv.Start: the netmon interface getter has to be in
	// place by then or the netlink route query inside Start fails (HarmonyOS
	// and Android 14 sandboxes deny it).
	ensureInterfaces()

	// logpolicy has no writable candidate on Android: it tries
	// /var/lib/tailscale (not permitted for an app), then os.UserCacheDir and
	// the cwd ("/"), then /tmp via os.MkdirTemp — and panics with "no safe
	// place found to store log state" when all of them fail. TS_LOGS_DIR is
	// consulted first, so point it at the app's own state directory.
	if os.Getenv("TS_LOGS_DIR") == "" {
		os.Setenv("TS_LOGS_DIR", stateDir)
	}

	// Surface Go-side logs where they can actually be read back: a file inside
	// stateDir. Android sends an app's stderr to /dev/null, so without this the
	// tsnet startup log is lost.
	var logWriter io.Writer = os.Stderr
	if lf, err := os.OpenFile(filepath.Join(stateDir, "bridge.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		logWriter = io.MultiWriter(os.Stderr, lf)
		defer lf.Close()
	}
	log.SetOutput(logWriter)

	srv := &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		AuthKey:  authKey,
		// Ephemeral nodes are removed from the tailnet when they go offline.
		// Set to false if you want a stable identity across restarts.
		Ephemeral: false,
		Logf: func(format string, args ...any) {
			fmt.Fprintf(logWriter, format+"\n", args...)
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// tsnet uses a userspace netstack by default; no TUN device is created.
	if err := srv.Start(); err != nil {
		recordError(stateDir, fmt.Errorf("srv.Start: %w", err))
		return 1
	}

	if _, err := srv.Up(ctx); err != nil {
		recordError(stateDir, fmt.Errorf("srv.Up: %w", err))
		_ = srv.Close()
		return 2
	}

	server = srv
	local, _ = srv.LocalClient()
	started = true
	stateMu.Lock()
	lastErr = ""
	stateMu.Unlock()
	return 0
}

// GetSelfInfo returns the local node's hostname and Tailscale IP as JSON.
// Returns an empty string if the node is not online.
func GetSelfInfo() string {
	mu.Lock()
	defer mu.Unlock()
	if !started || local == nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st, err := local.Status(ctx)
	if err != nil {
		return ""
	}
	info := SelfInfo{
		HostName: st.Self.HostName,
	}
	if len(st.Self.TailscaleIPs) > 0 {
		info.TailscaleIP = st.Self.TailscaleIPs[0].String()
	}
	b, _ := json.Marshal(info)
	return string(b)
}

// GetPeers returns the list of online peers as a JSON array of PeerInfo.
// Returns "[]" if the node is not online or no peers are found.
func GetPeers() string {
	mu.Lock()
	defer mu.Unlock()
	if !started || local == nil {
		return "[]"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st, err := local.Status(ctx)
	if err != nil {
		return "[]"
	}
	peers := make([]PeerInfo, 0, len(st.Peer))
	for _, p := range st.Peer {
		ip := ""
		if len(p.TailscaleIPs) > 0 {
			ip = p.TailscaleIPs[0].String()
		}
		peers = append(peers, PeerInfo{
			HostName:    p.HostName,
			TailscaleIP: ip,
			Online:      p.Online,
		})
	}
	b, _ := json.Marshal(peers)
	return string(b)
}

// Dial opens a connection through the Tailscale network.
// network: "tcp" or "udp". addr: "host:port".
// Returns a JSON object with a handle id used by Read/Write/CloseConn,
// or an error string starting with "error:".
func Dial(network, addr string) string {
	mu.Lock()
	defer mu.Unlock()
	if !started || server == nil {
		return `{"error":"not started"}`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := server.Dial(ctx, network, addr)
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	id := registerConn(conn)
	return fmt.Sprintf(`{"handle":%d}`, id)
}

// DialTls opens a TLS connection through the Tailscale network.
//
// LocalSend peers serve HTTPS with a per-device self-signed certificate, so
// the chain is deliberately not verified: the link is still encrypted, and
// peer identity is already pinned by the tailnet itself.
// Returns a handle id used by Read/Write/CloseConn, or an error string.
func DialTls(network, addr string) string {
	if network != "tcp" {
		return `{"error":"tls is tcp-only"}`
	}

	// Only guard the state read with mu: the dial + handshake below can take
	// tens of seconds and must not block the rest of the bridge.
	mu.Lock()
	serverRef := server
	running := started && server != nil
	mu.Unlock()
	if !running || serverRef == nil {
		return `{"error":"not started"}`
	}

	dialCtx, cancelDial := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancelDial()
	raw, err := serverRef.Dial(dialCtx, network, addr)
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}

	host, _, splitErr := net.SplitHostPort(addr)
	if splitErr != nil {
		host = addr
	}
	conn := tls.Client(raw, &tls.Config{
		// LocalSend ships a self-signed cert per device; there is no CA to
		// chain to, so verification is skipped on purpose.
		InsecureSkipVerify: true,
		ServerName:         host,
	})
	hsCtx, cancelHs := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancelHs()
	if err := conn.HandshakeContext(hsCtx); err != nil {
		raw.Close()
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}

	return fmt.Sprintf(`{"handle":%d}`, registerConn(conn))
}

// Listen opens a listener on the Tailscale network.
// Returns a handle id used by Accept/CloseListener, or an error string.
func Listen(network, addr string) string {
	mu.Lock()
	defer mu.Unlock()
	if !started || server == nil {
		return `{"error":"not started"}`
	}
	ln, err := server.Listen(network, addr)
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	id := registerListener(ln)
	return fmt.Sprintf(`{"handle":%d}`, id)
}

// Close shuts down the embedded Tailscale node and releases resources.
func Close() int {
	mu.Lock()
	defer mu.Unlock()
	if !started {
		return 0
	}
	closeAllConns()
	closeAllListeners()
	closeAllForwards()
	if server != nil {
		_ = server.Close()
	}
	server = nil
	local = nil
	started = false
	return 0
}

// IsStarted reports whether the node is up.
func IsStarted() bool {
	mu.Lock()
	defer mu.Unlock()
	return started
}

// ---- connection registry -------------------------------------------------

var (
	connMu       sync.Mutex
	connSeq      int64
	conns        = map[int64]net.Conn{}
	listenerSeq  int64
	listeners    = map[int64]net.Listener{}
)

func registerConn(c net.Conn) int64 {
	connMu.Lock()
	defer connMu.Unlock()
	connSeq++
	conns[connSeq] = c
	return connSeq
}

func registerListener(l net.Listener) int64 {
	connMu.Lock()
	defer connMu.Unlock()
	listenerSeq++
	listeners[listenerSeq] = l
	return listenerSeq
}

func getConn(id int64) net.Conn {
	connMu.Lock()
	defer connMu.Unlock()
	return conns[id]
}

func getListener(id int64) net.Listener {
	connMu.Lock()
	defer connMu.Unlock()
	return listeners[id]
}

// connIOTimeout bounds a single Read/Write on a tsnet connection. Without a
// deadline a stalled peer would block the host's worker thread forever.
const connIOTimeout = 60 * time.Second

// Read reads up to maxLen bytes from the connection identified by handle.
// Returns the bytes read (may be empty on EOF).
func Read(handle int64, maxLen int) ([]byte, error) {
	c := getConn(handle)
	if c == nil {
		return nil, errors.New("invalid handle")
	}
	_ = c.SetReadDeadline(time.Now().Add(connIOTimeout))
	buf := make([]byte, maxLen)
	n, err := c.Read(buf)
	if n > 0 {
		return buf[:n], err
	}
	return nil, err
}

// Write writes data to the connection identified by handle.
// Returns the number of bytes written.
func Write(handle int64, data []byte) (int, error) {
	c := getConn(handle)
	if c == nil {
		return 0, errors.New("invalid handle")
	}
	_ = c.SetWriteDeadline(time.Now().Add(connIOTimeout))
	return c.Write(data)
}

// CloseConn closes the connection identified by handle.
func CloseConn(handle int64) int {
	c := getConn(handle)
	if c == nil {
		return 1
	}
	connMu.Lock()
	delete(conns, handle)
	connMu.Unlock()
	_ = c.Close()
	return 0
}

// Accept accepts a new connection on the listener identified by handle.
// Blocks until a connection arrives. Returns a connection handle JSON.
// Android (gomobile) uses this synchronous form; HarmonyOS must not (its UI
// thread watchdog) and uses AcceptStart/AcceptPoll instead.
func Accept(handle int64) string {
	l := getListener(handle)
	if l == nil {
		return `{"error":"invalid handle"}`
	}
	c, err := l.Accept()
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	id := registerConn(c)
	return fmt.Sprintf(`{"handle":%d}`, id)
}

// acceptQueue holds connection handles accepted by AcceptStart goroutines,
// keyed by listener handle, waiting for the host to AcceptPoll them.
var acceptQueue = map[int64][]int64{}

// acceptErrs holds the failure reported by an AcceptStart goroutine (set
// when the listener is closed or breaks), consumed by the next AcceptPoll.
var acceptErrs = map[int64]string{}

// AcceptStart launches a blocking Accept on a background goroutine and
// returns immediately (0). Results are retrieved with AcceptPoll. The host's
// UI thread must never sit inside a blocking cgo call: HarmonyOS kills the
// process after 6 s of an unresponsive main thread (THREAD_BLOCK_6S).
func AcceptStart(handle int64) int {
	l := getListener(handle)
	if l == nil {
		return 1
	}
	go func() {
		c, err := l.Accept()
		if err != nil {
			connMu.Lock()
			acceptErrs[handle] = err.Error()
			connMu.Unlock()
			return
		}
		id := registerConn(c)
		connMu.Lock()
		acceptQueue[handle] = append(acceptQueue[handle], id)
		connMu.Unlock()
	}()
	return 0
}

// AcceptPoll pops one accepted connection handle for the listener:
// {"handle":N} when one is queued, {"handle":0} while none has arrived yet,
// or {"error":"..."} once the accept goroutine failed (e.g. listener closed).
func AcceptPoll(handle int64) string {
	connMu.Lock()
	if ids := acceptQueue[handle]; len(ids) > 0 {
		id := ids[0]
		acceptQueue[handle] = ids[1:]
		connMu.Unlock()
		return fmt.Sprintf(`{"handle":%d}`, id)
	}
	errStr, failed := acceptErrs[handle]
	if failed {
		delete(acceptErrs, handle)
		connMu.Unlock()
		return fmt.Sprintf(`{"error":%q}`, errStr)
	}
	connMu.Unlock()
	return `{"handle":0}`
}

// CloseListener closes the listener identified by handle.
func CloseListener(handle int64) int {
	l := getListener(handle)
	if l == nil {
		return 1
	}
	connMu.Lock()
	delete(listeners, handle)
	delete(acceptQueue, handle)
	delete(acceptErrs, handle)
	connMu.Unlock()
	_ = l.Close()
	return 0
}

func closeAllConns() {
	connMu.Lock()
	defer connMu.Unlock()
	for id, c := range conns {
		_ = c.Close()
		delete(conns, id)
	}
}

func closeAllListeners() {
	connMu.Lock()
	defer connMu.Unlock()
	for id, l := range listeners {
		_ = l.Close()
		delete(listeners, id)
	}
}

// ---- loopback port forwarding -------------------------------------------
//
// tsnet is a userspace netstack: there is no kernel TUN interface, so the
// host's ordinary sockets cannot reach 100.x addresses. Native channels (the
// scrcpy video/control readers) still need a plain file descriptor, so each
// Tailscale endpoint is exposed on a loopback port and relayed in Go.

type portForward struct {
	ln     net.Listener
	target string
	closed chan struct{}
	once   sync.Once
}

var (
	fwdMu    sync.Mutex
	fwdSeq   int64
	forwards = map[int64]*portForward{}
)

// ForwardTCP listens on 127.0.0.1:localPort and relays every accepted
// connection to target ("host:port") through the Tailscale network.
// Pass localPort 0 to let the OS choose a free port; the chosen one is
// returned as {"handle":N,"port":P}, or {"error":"..."} on failure.
func ForwardTCP(localPort int, target string) string {
	mu.Lock()
	ready := started && server != nil
	mu.Unlock()
	if !ready {
		return `{"error":"not started"}`
	}

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", localPort))
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	f := &portForward{ln: ln, target: target, closed: make(chan struct{})}

	fwdMu.Lock()
	fwdSeq++
	id := fwdSeq
	forwards[id] = f
	fwdMu.Unlock()

	go f.run()
	port := ln.Addr().(*net.TCPAddr).Port
	return fmt.Sprintf(`{"handle":%d,"port":%d}`, id, port)
}

// CloseForward stops the loopback listener and its relayed connections.
func CloseForward(handle int64) int {
	fwdMu.Lock()
	f := forwards[handle]
	delete(forwards, handle)
	fwdMu.Unlock()
	if f == nil {
		return 1
	}
	f.once.Do(func() { close(f.closed) })
	_ = f.ln.Close()
	return 0
}

func closeAllForwards() {
	fwdMu.Lock()
	all := forwards
	forwards = map[int64]*portForward{}
	fwdMu.Unlock()
	for _, f := range all {
		f.once.Do(func() { close(f.closed) })
		_ = f.ln.Close()
	}
}

func (f *portForward) run() {
	for {
		local, err := f.ln.Accept()
		if err != nil {
			return
		}
		go f.serve(local)
	}
}

func (f *portForward) serve(local net.Conn) {
	defer func() { _ = local.Close() }()

	mu.Lock()
	srv := server
	mu.Unlock()
	if srv == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	remote, err := srv.Dial(ctx, "tcp", f.target)
	cancel()
	if err != nil {
		log.Printf("forward %s: dial failed: %v", f.target, err)
		return
	}
	defer func() { _ = remote.Close() }()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(remote, local)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(local, remote)
		done <- struct{}{}
	}()
	<-done
}
