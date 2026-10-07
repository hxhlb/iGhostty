//go:build !linux

package relay

import (
	"net"
	"time"
)

// setUserTimeout is Linux's TCP_USER_TIMEOUT; elsewhere keepalive is all
// there is.
func setUserTimeout(*net.TCPConn, time.Duration) {}
