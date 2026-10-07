//go:build linux

package relay

import (
	"net"
	"syscall"
	"time"
)

// tcpUserTimeout is TCP_USER_TIMEOUT from <linux/tcp.h>; the syscall
// package does not name it on every architecture.
const tcpUserTimeout = 0x12

// setUserTimeout bounds how long sent data may go unacknowledged before the
// kernel gives the connection up — what ends a write to a peer that vanished,
// which keepalive alone does not while data is queued.
func setUserTimeout(conn *net.TCPConn, d time.Duration) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return
	}
	raw.Control(func(fd uintptr) {
		syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpUserTimeout, int(d/time.Millisecond))
	})
}
