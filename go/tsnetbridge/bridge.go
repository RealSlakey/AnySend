// Package tsnetbridge wraps Tailscale's tsnet library for embedding in
// Android (via gomobile AAR) and HarmonyOS NEXT (via c-shared .so + NAPI).
//
// It uses tsnet's built-in userspace netstack, so no TUN/VPN permission
// is required from the host OS.
package tsnetbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"tailscale.com/client/tailscale"
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
	mu      sync.Mutex
	server  *tsnet.Server
	local   *tailscale.LocalClient
	started bool
)

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

	srv := &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		AuthKey:  authKey,
		// Ephemeral nodes are removed from the tailnet when they go offline.
		// Set to false if you want a stable identity across restarts.
		Ephemeral: false,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// tsnet uses a userspace netstack by default; no TUN device is created.
	if err := srv.Start(); err != nil {
		_ = err
		return 1
	}

	if _, err := srv.Up(ctx); err != nil {
		_ = srv.Close()
		return 2
	}

	server = srv
	local, _ = srv.LocalClient()
	started = true
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

// Read reads up to maxLen bytes from the connection identified by handle.
// Returns the bytes read (may be empty on EOF).
func Read(handle int64, maxLen int) ([]byte, error) {
	c := getConn(handle)
	if c == nil {
		return nil, errors.New("invalid handle")
	}
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

// CloseListener closes the listener identified by handle.
func CloseListener(handle int64) int {
	l := getListener(handle)
	if l == nil {
		return 1
	}
	connMu.Lock()
	delete(listeners, handle)
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
