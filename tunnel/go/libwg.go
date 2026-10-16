// libwg: thin C API over wireguard-go for the Phone Agent PacketTunnel
// extension. Modeled on wireguard-apple's api-apple.go.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

type wgConfig struct {
	PrivateKey    string   `json:"privateKey"`
	PeerPublicKey string   `json:"peerPublicKey"`
	Endpoint      string   `json:"endpoint"`
	AllowedIPs    []string `json:"allowedIPs"`
	Keepalive     int      `json:"keepalive"`
}

var (
	mu         sync.Mutex
	handles    = map[int32]*device.Device{}
	nextHandle int32 = 1

	logMu  sync.Mutex
	logBuf strings.Builder
)

const maxLog = 64 * 1024

func appendLog(format string, args ...any) {
	line := time.Now().Format("15:04:05 ") + fmt.Sprintf(format, args...) + "\n"
	logMu.Lock()
	defer logMu.Unlock()
	if logBuf.Len()+len(line) > maxLog {
		s := logBuf.String()
		logBuf.Reset()
		logBuf.WriteString(s[len(s)/2:])
	}
	logBuf.WriteString(line)
}

func keyToHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("key length %d != 32", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

func buildUAPI(cfg *wgConfig) (string, error) {
	priv, err := keyToHex(cfg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("privateKey: %w", err)
	}
	pub, err := keyToHex(cfg.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peerPublicKey: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\nreplace_peers=true\n", priv)
	fmt.Fprintf(&b, "public_key=%s\nendpoint=%s\n", pub, cfg.Endpoint)
	if cfg.Keepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", cfg.Keepalive)
	}
	b.WriteString("replace_allowed_ips=true\n")
	for _, ip := range cfg.AllowedIPs {
		fmt.Fprintf(&b, "allowed_ip=%s\n", ip)
	}
	return b.String(), nil
}

// wgGenerateKeyPair returns "<private b64> <public b64>". Caller frees.
//
//export wgGenerateKeyPair
func wgGenerateKeyPair() *C.char {
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		return nil
	}
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		return nil
	}
	return C.CString(base64.StdEncoding.EncodeToString(priv[:]) + " " + base64.StdEncoding.EncodeToString(pub))
}

// wgTurnOn starts a WireGuard device on an already-open utun fd.
// Returns a handle > 0, or a negative error code (details in wgDrainLog).
//
//export wgTurnOn
func wgTurnOn(configJSON *C.char, tunFd C.int, mtu C.int) C.int {
	var cfg wgConfig
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &cfg); err != nil {
		appendLog("config json: %v", err)
		return -1
	}
	uapi, err := buildUAPI(&cfg)
	if err != nil {
		appendLog("config: %v", err)
		return -1
	}

	dupFd, err := unix.Dup(int(tunFd))
	if err != nil {
		appendLog("dup tun fd: %v", err)
		return -2
	}
	if err := unix.SetNonblock(dupFd, true); err != nil {
		unix.Close(dupFd)
		appendLog("nonblock: %v", err)
		return -2
	}
	tunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupFd), "/dev/tun"), int(mtu))
	if err != nil {
		unix.Close(dupFd)
		appendLog("CreateTUNFromFile: %v", err)
		return -3
	}
	name, _ := tunDev.Name()

	logger := &device.Logger{
		Verbosef: func(f string, a ...any) { appendLog("wg: "+f, a...) },
		Errorf:   func(f string, a ...any) { appendLog("wg ERROR: "+f, a...) },
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	// iOS hands the tunnel a new socket path on every Wi-Fi/cellular switch;
	// same quirk wireguard-apple applies.
	dev.DisableSomeRoamingForBrokenMobileSemantics()
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		appendLog("IpcSet: %v", err)
		return -4
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		appendLog("Up: %v", err)
		return -5
	}
	appendLog("wireguard up on %s, endpoint %s", name, cfg.Endpoint)

	mu.Lock()
	h := nextHandle
	nextHandle++
	handles[h] = dev
	mu.Unlock()
	return C.int(h)
}

//export wgTurnOff
func wgTurnOff(handle C.int) {
	mu.Lock()
	dev, ok := handles[int32(handle)]
	delete(handles, int32(handle))
	mu.Unlock()
	if ok {
		dev.Close()
		appendLog("wireguard down")
	}
}

// wgBumpSockets rebinds the UDP sockets after a network path change
// (Wi-Fi <-> cellular, wake from sleep).
//
//export wgBumpSockets
func wgBumpSockets(handle C.int) {
	mu.Lock()
	dev, ok := handles[int32(handle)]
	mu.Unlock()
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			if err := dev.BindUpdate(); err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				appendLog("sockets rebound")
				return
			} else {
				appendLog("BindUpdate failed (%d): %v", i, err)
			}
			time.Sleep(time.Second / 2)
		}
	}()
}

// wgGetStats returns JSON {"handshake":<unix sec>,"rx":<bytes>,"tx":<bytes>}.
//
//export wgGetStats
func wgGetStats(handle C.int) *C.char {
	mu.Lock()
	dev, ok := handles[int32(handle)]
	mu.Unlock()
	if !ok {
		return C.CString(`{"error":"no device"}`)
	}
	s, err := dev.IpcGet()
	if err != nil {
		return C.CString(fmt.Sprintf(`{"error":%q}`, err.Error()))
	}
	var hs, rx, tx int64
	for _, line := range strings.Split(s, "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		n, _ := strconv.ParseInt(v, 10, 64)
		switch k {
		case "last_handshake_time_sec":
			hs = n
		case "rx_bytes":
			rx = n
		case "tx_bytes":
			tx = n
		}
	}
	return C.CString(fmt.Sprintf(`{"handshake":%d,"rx":%d,"tx":%d}`, hs, rx, tx))
}

// wgDrainLog returns and clears the accumulated log. Caller frees.
//
//export wgDrainLog
func wgDrainLog() *C.char {
	logMu.Lock()
	s := logBuf.String()
	logBuf.Reset()
	logMu.Unlock()
	return C.CString(s)
}

func main() {}
