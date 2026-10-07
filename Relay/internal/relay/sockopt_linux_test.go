//go:build linux

package relay

import (
	"net"
	"syscall"
	"testing"
)

func TestTuneSetsKeepaliveAndUserTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err == nil {
			defer c.Close()
			c.Read(make([]byte, 1))
		}
	}()
	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	tune(conn)
	raw, _ := conn.(*net.TCPConn).SyscallConn()
	want := map[string][3]int{
		"SO_KEEPALIVE":     {syscall.SOL_SOCKET, syscall.SO_KEEPALIVE, 1},
		"TCP_KEEPIDLE":     {syscall.IPPROTO_TCP, syscall.TCP_KEEPIDLE, 10},
		"TCP_KEEPINTVL":    {syscall.IPPROTO_TCP, syscall.TCP_KEEPINTVL, 5},
		"TCP_KEEPCNT":      {syscall.IPPROTO_TCP, syscall.TCP_KEEPCNT, 3},
		"TCP_USER_TIMEOUT": {syscall.IPPROTO_TCP, tcpUserTimeout, 25000},
	}
	raw.Control(func(fd uintptr) {
		for name, w := range want {
			got, err := syscall.GetsockoptInt(int(fd), w[0], w[1])
			if err != nil || got != w[2] {
				t.Errorf("%s = %d, %v; want %d", name, got, err, w[2])
			}
		}
	})
}
