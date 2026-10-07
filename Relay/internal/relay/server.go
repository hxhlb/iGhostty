// Package relay is the relay itself: one listener that tells a TLS
// ClientHello from a control connection by its first byte, routes the former
// by SNI to a registered host, and splices the two TCP connections once the
// host calls back. It never terminates TLS; it sees ciphertext only.
package relay

import (
	"crypto/ecdsa"
	"errors"
	"io"
	"log"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
)

// Limits are PROTOCOL.md's numbers. Tests shorten the clocks; nothing else
// changes them.
type Limits struct {
	Hosts            int           // registered hosts
	TicketsPerHost   int           // tickets waiting for one host's accept
	Splices          int           // splices, counted from the ticket on
	PreSNI           int           // connections that have not produced an SNI
	PreRequest       int           // control connections that have not sent their request
	RatePerIP        int           // data connections per source address...
	RateWindow       time.Duration // ...per this window
	HandshakeTimeout time.Duration // first record, or magic and request
	TicketLife       time.Duration
	HostSilence      time.Duration // a host that sends nothing this long is dropped
	WriteTimeout     time.Duration // one control frame to a host
	PendingBytes     int           // client bytes held while the host calls back
}

// DefaultLimits are the protocol's.
func DefaultLimits() Limits {
	return Limits{
		Hosts:            64,
		TicketsPerHost:   32,
		Splices:          512,
		PreSNI:           64,
		PreRequest:       64,
		RatePerIP:        60,
		RateWindow:       10 * time.Second,
		HandshakeTimeout: 5 * time.Second,
		TicketLife:       10 * time.Second,
		HostSilence:      200 * time.Second,
		WriteTimeout:     10 * time.Second,
		PendingBytes:     64 * 1024,
	}
}

// EndpointFunc says where clients reach the relay, `host:port`, and how that
// was decided (for the log).
type EndpointFunc func() (endpoint, how string, err error)

// Options configure a Server.
type Options struct {
	Dir      store.Dir
	Name     string
	Version  string // the binary's, for the log
	Endpoint EndpointFunc
	Limits   Limits
	Logger   *log.Logger
	// RetryEndpoint is the first delay before asking Endpoint again after it
	// failed at start; it doubles up to ten minutes. Zero means a minute.
	RetryEndpoint time.Duration
}

// Server is a running relay.
type Server struct {
	opts   Options
	limits Limits
	log    *log.Logger

	keyMu sync.Mutex // serialises the key files: start, retry, rotate

	mu        sync.Mutex
	relayID   string
	relayKey  *ecdsa.PublicKey // nil until a key exists
	keyGen    int              // bumped by rotate; a registration checked against an older key loses
	endpoint  string
	bindings  map[string]store.Binding
	hosts     map[string]*hostConn // by lower-case id
	tickets   map[string]*splice
	splices   int
	preSNI    int
	preReq    int
	listeners []net.Listener
	closed    bool
	rate      *rateLimiter
	stop      chan struct{}
}

// New prepares a server: it loads (or makes) the relay's key and writes the
// configuration, as PROTOCOL.md and the README describe. It does not listen.
func New(opts Options) (*Server, error) {
	if opts.Logger == nil {
		opts.Logger = log.New(io.Discard, "", 0)
	}
	if opts.Limits == (Limits{}) {
		opts.Limits = DefaultLimits()
	}
	if opts.RetryEndpoint == 0 {
		opts.RetryEndpoint = time.Minute
	}
	s := &Server{
		opts:    opts,
		limits:  opts.Limits,
		log:     opts.Logger,
		hosts:   map[string]*hostConn{},
		tickets: map[string]*splice{},
		rate:    newRateLimiter(opts.Limits.RatePerIP, opts.Limits.RateWindow),
		stop:    make(chan struct{}),
	}
	bindings, err := opts.Dir.LoadBindings()
	if err != nil {
		return nil, err
	}
	s.bindings = bindings
	if err := s.prepareKey(); err != nil {
		return nil, err
	}
	return s, nil
}

// Serve accepts connections until the listener is closed.
func (s *Server) Serve(ln net.Listener) error {
	if !s.track(ln) {
		return net.ErrClosed
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			return err
		}
		go s.handle(conn)
	}
}

// Close stops listening and drops every connection the relay holds.
func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	close(s.stop)
	listeners := s.listeners
	hosts := make([]*hostConn, 0, len(s.hosts))
	for _, h := range s.hosts {
		hosts = append(hosts, h)
	}
	s.mu.Unlock()
	for _, ln := range listeners {
		ln.Close()
	}
	for _, h := range hosts {
		s.dropHost(h)
	}
}

func (s *Server) track(ln net.Listener) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		ln.Close()
		return false
	}
	s.listeners = append(s.listeners, ln)
	return true
}

// handle reads the first byte and hands the connection to its kind. Until
// that byte and the SNI behind it are in, the connection counts against
// PreSNI.
func (s *Server) handle(conn net.Conn) {
	tune(conn)
	if !s.acquire(&s.preSNI, s.limits.PreSNI) {
		conn.Close()
		return
	}
	conn.SetDeadline(time.Now().Add(s.limits.HandshakeTimeout))
	var first [1]byte
	if _, err := io.ReadFull(conn, first[:]); err != nil {
		s.release(&s.preSNI)
		conn.Close()
		return
	}
	switch first[0] {
	case 0x16:
		s.handleData(conn, first[0])
	case protocol.Magic[0]:
		s.release(&s.preSNI)
		if !s.acquire(&s.preReq, s.limits.PreRequest) {
			conn.Close()
			return
		}
		s.handleControl(conn)
	default:
		s.release(&s.preSNI)
		conn.Close()
	}
}

func (s *Server) acquire(counter *int, limit int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if *counter >= limit {
		return false
	}
	*counter++
	return true
}

func (s *Server) release(counter *int) {
	s.mu.Lock()
	*counter--
	s.mu.Unlock()
}

// remoteIP is a connection's source address without its port.
func remoteIP(conn net.Conn) netip.Addr {
	if ap, err := netip.ParseAddrPort(conn.RemoteAddr().String()); err == nil {
		return ap.Addr().Unmap()
	}
	return netip.Addr{}
}

// tune gives a connection the protocol's keepalive and user timeout.
func tune(conn net.Conn) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	tcp.SetKeepAliveConfig(net.KeepAliveConfig{
		Enable:   true,
		Idle:     10 * time.Second,
		Interval: 5 * time.Second,
		Count:    3,
	})
	setUserTimeout(tcp, 25*time.Second)
}
