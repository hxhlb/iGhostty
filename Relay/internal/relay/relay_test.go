package relay

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/testhello"
)

const testEndpoint = "relay.example.com:46405"

type harness struct {
	t      *testing.T
	s      *Server
	addr   string
	dir    store.Dir
	member *ecdsa.PrivateKey // the configuration's key
	id     string            // relayID
	logs   *syncBuffer
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

func fastLimits() Limits {
	l := DefaultLimits()
	l.HandshakeTimeout = 2 * time.Second
	l.TicketLife = 2 * time.Second
	return l
}

func start(t *testing.T, limits Limits) *harness {
	t.Helper()
	return startIn(t, store.Dir(t.TempDir()), limits)
}

func startIn(t *testing.T, dir store.Dir, limits Limits) *harness {
	t.Helper()
	logs := &syncBuffer{}
	s, err := New(Options{
		Dir:      dir,
		Name:     "test relay",
		Version:  "test",
		Endpoint: func() (string, string, error) { return testEndpoint, "test", nil },
		Limits:   limits,
		Logger:   log.New(logs, "", 0),
	})
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go s.Serve(ln)
	t.Cleanup(s.Close)
	h := &harness{t: t, s: s, addr: ln.Addr().String(), dir: dir, logs: logs}
	h.loadMember()
	return h
}

func (h *harness) loadMember() {
	c, err := h.dir.LoadConfig()
	if err != nil || c == nil {
		h.t.Fatalf("no configuration: %v", err)
	}
	priv, err := protocol.ParsePrivateKey(c.Key)
	if err != nil {
		h.t.Fatal(err)
	}
	h.member, h.id = priv, c.RelayID
}

func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func sign(t *testing.T, k *ecdsa.PrivateKey, message []byte) string {
	t.Helper()
	digest := sha256.Sum256(message)
	sig, err := ecdsa.SignASN1(rand.Reader, k, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func spki(t *testing.T, k *ecdsa.PrivateKey) string {
	t.Helper()
	s, err := protocol.EncodePublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func (h *harness) dial() net.Conn {
	h.t.Helper()
	c, err := net.Dial("tcp", h.addr)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(10 * time.Second))
	return c
}

// control opens a control connection and reads the hello.
func (h *harness) control(version byte) (net.Conn, protocol.Hello) {
	h.t.Helper()
	c := h.dial()
	if _, err := c.Write(append([]byte(protocol.Magic), version)); err != nil {
		h.t.Fatal(err)
	}
	var hello protocol.Hello
	readJSON(h.t, c, &hello)
	return c, hello
}

func readJSON(t *testing.T, c net.Conn, v any) {
	t.Helper()
	body, err := protocol.ReadFrame(c)
	if err != nil {
		t.Fatalf("reading a frame: %v", err)
	}
	if err := json.Unmarshal(body, v); err != nil {
		t.Fatal(err)
	}
}

func send(t *testing.T, c net.Conn, v any) {
	t.Helper()
	if err := protocol.WriteFrame(c, v); err != nil {
		t.Fatal(err)
	}
}

func answer(t *testing.T, c net.Conn) protocol.Answer {
	t.Helper()
	var a protocol.Answer
	readJSON(t, c, &a)
	return a
}

// expectClosed waits for the relay to close c.
func expectClosed(t *testing.T, c net.Conn) {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 1024)
	for {
		_, err := c.Read(buf)
		if err == nil {
			continue
		}
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			t.Fatal("the relay did not close the connection")
		}
		return
	}
}

type host struct {
	id   string
	key  *ecdsa.PrivateKey
	conn net.Conn
}

func (h *harness) hostRequest(hostID string, member, hostKey *ecdsa.PrivateKey, nonce string) protocol.Request {
	message := protocol.SignedMessage(protocol.RoleHost, h.id, nonce, hostID)
	return protocol.Request{
		Role: protocol.RoleHost, HostID: hostID, Name: "Office Mac", AppVersion: "1.4.0",
		HostKey: spki(h.t, hostKey), Sig: sign(h.t, member, message), HostSig: sign(h.t, hostKey, message),
	}
}

// register registers a host and expects reason ("" for ok).
func (h *harness) register(hostID string, key *ecdsa.PrivateKey, reason string) *host {
	h.t.Helper()
	c, hello := h.control(protocol.Version)
	send(h.t, c, h.hostRequest(hostID, h.member, key, hello.Nonce))
	a := answer(h.t, c)
	if reason == "" && !a.OK || reason != "" && a.Reason != reason {
		h.t.Fatalf("register %s: got %+v, want %q", hostID, a, reason)
	}
	return &host{id: hostID, key: key, conn: c}
}

func (h *harness) list() protocol.ListAnswer {
	h.t.Helper()
	c, hello := h.control(protocol.Version)
	send(h.t, c, protocol.Request{Role: protocol.RoleList,
		Sig: sign(h.t, h.member, protocol.SignedMessage(protocol.RoleList, h.id, hello.Nonce, ""))})
	var a protocol.ListAnswer
	readJSON(h.t, c, &a)
	return a
}

func (hs *host) incoming(t *testing.T) protocol.Message {
	t.Helper()
	var m protocol.Message
	readJSON(t, hs.conn, &m)
	if m.Type != "incoming" {
		t.Fatalf("got %+v", m)
	}
	return m
}

// accept sends the accept before reading the hello, as hosts do, and
// returns the connection and the answer.
func (h *harness) accept(ticket string, key *ecdsa.PrivateKey) (net.Conn, protocol.Answer) {
	h.t.Helper()
	c := h.dial()
	frame, _ := protocol.EncodeFrame(protocol.Request{Role: protocol.RoleAccept, Ticket: ticket,
		HostSig: sign(h.t, key, protocol.SignedMessage(protocol.RoleAccept, h.id, "", ticket))})
	if _, err := c.Write(append(append([]byte(protocol.Magic), protocol.Version), frame...)); err != nil {
		h.t.Fatal(err)
	}
	var hello protocol.Hello
	readJSON(h.t, c, &hello)
	return c, answer(h.t, c)
}

// client opens a data connection naming hostID and sends its ClientHello.
func (h *harness) client(hostID string, extra []byte) (net.Conn, []byte) {
	h.t.Helper()
	c := h.dial()
	sent := append(testhello.Hello(hostID), extra...)
	if _, err := c.Write(sent); err != nil {
		h.t.Fatal(err)
	}
	return c, sent
}

const hostA = "6F1C2A7E-0B3D-4C5E-8F90-123456789ABC"
const hostB = "0A1B2C3D-4E5F-4A6B-8C7D-0123456789EF"

func TestSignedMessage(t *testing.T) {
	got := string(protocol.SignedMessage("host", "RID", "Tm9uY2U=", "HID"))
	if got != "ighostvt-relay-v1\nhost\nRID\nTm9uY2U=\nHID" {
		t.Fatalf("%q", got)
	}
	if got := string(protocol.SignedMessage("accept", "RID", "", "T")); got != "ighostvt-relay-v1\naccept\nRID\n\nT" {
		t.Fatalf("%q", got)
	}
}

func TestFirstStartWritesConfiguration(t *testing.T) {
	h := start(t, fastLimits())
	info, err := os.Stat(h.dir.ConfigPath())
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("configuration mode %v", info.Mode().Perm())
	}
	c, _ := h.dir.LoadConfig()
	if c.Format != "ighostvt-relay" || c.Version != 1 || c.Endpoint != testEndpoint || c.Name != "test relay" {
		t.Errorf("configuration %+v", c)
	}
	if c.RelayID != strings.ToUpper(c.RelayID) || len(c.RelayID) != 36 {
		t.Errorf("relay id %q", c.RelayID)
	}
	raw, _ := base64.StdEncoding.DecodeString(c.Key)
	if len(raw) != 32 {
		t.Errorf("key is %d bytes", len(raw))
	}
	relayJSON, _ := os.ReadFile(filepath.Join(string(h.dir), "relay.json"))
	if bytes.Contains(relayJSON, []byte(c.Key)) {
		t.Error("relay.json holds the private key")
	}
	if strings.Contains(h.logs.String(), c.Key) {
		t.Error("the log holds the private key")
	}
	if !strings.Contains(h.logs.String(), SaveCommand) {
		t.Error("the log does not say how to get the configuration")
	}
}

func TestRegisterAndList(t *testing.T) {
	h := start(t, fastLimits())
	h.register(hostA, newKey(t), "")
	l := h.list()
	if !l.OK || len(l.Hosts) != 1 {
		t.Fatalf("%+v", l)
	}
	got := l.Hosts[0]
	if got.ID != hostA || got.Name != "Office Mac" || got.AppVersion != "1.4.0" || got.Since == 0 {
		t.Fatalf("%+v", got)
	}
}

func TestListEmptyHasHosts(t *testing.T) {
	h := start(t, fastLimits())
	c, hello := h.control(protocol.Version)
	send(t, c, protocol.Request{Role: protocol.RoleList,
		Sig: sign(t, h.member, protocol.SignedMessage(protocol.RoleList, h.id, hello.Nonce, ""))})
	body, err := protocol.ReadFrame(c)
	if err != nil || string(body) != `{"ok":true,"hosts":[]}` {
		t.Fatalf("%s %v", body, err)
	}
}

func TestHello(t *testing.T) {
	h := start(t, fastLimits())
	_, hello := h.control(protocol.Version)
	nonce, err := base64.StdEncoding.DecodeString(hello.Nonce)
	if hello.Relay != "ighostvt-relay" || hello.Version != 1 || hello.RelayID != h.id || err != nil || len(nonce) != 32 {
		t.Fatalf("%+v", hello)
	}
}

func TestWrongRelayKey(t *testing.T) {
	h := start(t, fastLimits())
	c, hello := h.control(protocol.Version)
	send(t, c, h.hostRequest(hostA, newKey(t), newKey(t), hello.Nonce))
	if a := answer(t, c); a.OK || a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}
	c, hello = h.control(protocol.Version)
	send(t, c, protocol.Request{Role: protocol.RoleList,
		Sig: sign(t, newKey(t), protocol.SignedMessage(protocol.RoleList, h.id, hello.Nonce, ""))})
	if a := answer(t, c); a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}
}

// A signature over one connection's nonce is no good on another.
func TestNonceReplay(t *testing.T) {
	h := start(t, fastLimits())
	_, first := h.control(protocol.Version)
	req := h.hostRequest(hostA, h.member, newKey(t), first.Nonce)
	c, second := h.control(protocol.Version)
	if second.Nonce == first.Nonce {
		t.Fatal("two connections got one nonce")
	}
	send(t, c, req)
	if a := answer(t, c); a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}
}

func TestWrongHostSig(t *testing.T) {
	h := start(t, fastLimits())
	c, hello := h.control(protocol.Version)
	req := h.hostRequest(hostA, h.member, newKey(t), hello.Nonce)
	req.HostSig = sign(t, newKey(t), protocol.SignedMessage(protocol.RoleHost, h.id, hello.Nonce, hostA))
	send(t, c, req)
	if a := answer(t, c); a.Reason != protocol.ReasonHostKey {
		t.Fatalf("%+v", a)
	}
}

func TestMalformedRequest(t *testing.T) {
	h := start(t, fastLimits())
	for _, req := range []protocol.Request{
		{Role: "nobody"},
		{Role: protocol.RoleHost, HostID: "not-a-uuid"},
		{Role: protocol.RoleAccept},
	} {
		c, _ := h.control(protocol.Version)
		send(t, c, req)
		if a := answer(t, c); a.Reason != protocol.ReasonInvalid {
			t.Errorf("%+v: %+v", req, a)
		}
	}
	c, hello := h.control(protocol.Version)
	req := h.hostRequest(hostA, h.member, newKey(t), hello.Nonce)
	req.HostKey = "AAAA"
	send(t, c, req)
	if a := answer(t, c); a.Reason != protocol.ReasonInvalid {
		t.Errorf("bad host key: %+v", a)
	}
}

func TestVersionMismatch(t *testing.T) {
	h := start(t, fastLimits())
	c, hello := h.control(2)
	if hello.Version != protocol.Version {
		t.Fatalf("%+v", hello)
	}
	if a := answer(t, c); a.OK || a.Reason != protocol.ReasonVersion {
		t.Fatalf("%+v", a)
	}
	expectClosed(t, c)
}

func TestTrustOnFirstUseAndForget(t *testing.T) {
	h := start(t, fastLimits())
	first, second := newKey(t), newKey(t)
	hs := h.register(hostA, first, "")
	hs.conn.Close()
	h.register(hostA, second, protocol.ReasonHostKey)
	// The binding is keyed by the lower-case id: another spelling is the same host.
	h.register(strings.ToLower(hostA), second, protocol.ReasonHostKey)

	// The binding survives a restart.
	h.s.Close()
	h2 := startIn(t, h.dir, fastLimits())
	h2.register(hostA, second, protocol.ReasonHostKey)

	if _, err := h2.s.Forget(strings.ToLower(hostA)); err != nil {
		t.Fatal(err)
	}
	h2.register(hostA, second, "")
}

func TestForgetDropsTheOnlineHost(t *testing.T) {
	h := start(t, fastLimits())
	hs := h.register(hostA, newKey(t), "")
	if _, err := h.s.Forget(hostA); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, hs.conn)
}

func TestSuperseded(t *testing.T) {
	h := start(t, fastLimits())
	key := newKey(t)
	old := h.register(hostA, key, "")
	h.register(hostA, key, "")
	var m protocol.Message
	readJSON(t, old.conn, &m)
	if m.Type != "superseded" {
		t.Fatalf("%+v", m)
	}
	expectClosed(t, old.conn)
	if l := h.list(); len(l.Hosts) != 1 {
		t.Fatalf("%+v", l)
	}
}

func TestPingPongAndSilence(t *testing.T) {
	l := fastLimits()
	l.HostSilence = 300 * time.Millisecond
	h := start(t, l)
	hs := h.register(hostA, newKey(t), "")
	for range 3 {
		time.Sleep(150 * time.Millisecond)
		send(t, hs.conn, protocol.Message{Type: "ping"})
		var m protocol.Message
		readJSON(t, hs.conn, &m)
		if m.Type != "pong" {
			t.Fatalf("%+v", m)
		}
	}
	expectClosed(t, hs.conn)
	if l := h.list(); len(l.Hosts) != 0 {
		t.Fatalf("a silent host is still listed: %+v", l)
	}
}

func TestHandshakeTimeout(t *testing.T) {
	l := fastLimits()
	l.HandshakeTimeout = 200 * time.Millisecond
	h := start(t, l)
	c := h.dial()
	c.Write([]byte(protocol.Magic + "\x01"))
	var hello protocol.Hello
	readJSON(t, c, &hello)
	expectClosed(t, c)

	data := h.dial()
	data.Write(testhello.Hello(hostA)[:20])
	expectClosed(t, data)
}

func TestUnknownFirstByte(t *testing.T) {
	h := start(t, fastLimits())
	c := h.dial()
	c.Write([]byte("GET / HTTP/1.1\r\n\r\n"))
	expectClosed(t, c)
}

// The whole data path: SNI, incoming, accept (sent before the hello), the
// client's bytes replayed to the host, then both directions.
func TestSplice(t *testing.T) {
	h := start(t, fastLimits())
	key := newKey(t)
	hs := h.register(hostA, key, "")

	client, sent := h.client(strings.ToLower(hostA)+".", []byte("more"))
	m := hs.incoming(t)
	if m.From != "127.0.0.1" || len(m.Ticket) != 22 || strings.ContainsAny(m.Ticket, "+/=") {
		t.Fatalf("%+v", m)
	}
	leg, a := h.accept(m.Ticket, key)
	if !a.OK {
		t.Fatalf("%+v", a)
	}
	got := make([]byte, len(sent))
	if _, err := io.ReadFull(leg, got); err != nil || !bytes.Equal(got, sent) {
		t.Fatalf("host got %q, %v", got, err)
	}
	leg.Write([]byte("server hello"))
	reply := make([]byte, len("server hello"))
	if _, err := io.ReadFull(client, reply); err != nil || string(reply) != "server hello" {
		t.Fatalf("client got %q, %v", reply, err)
	}
	big := bytes.Repeat([]byte("x"), 300*1024)
	go client.Write(big)
	got = make([]byte, len(big))
	if _, err := io.ReadFull(leg, got); err != nil || !bytes.Equal(got, big) {
		t.Fatalf("host got %d bytes, %v", len(got), err)
	}

	// A ticket is good once.
	again, a := h.accept(m.Ticket, key)
	if a.Reason != protocol.ReasonTicket {
		t.Fatalf("%+v", a)
	}
	expectClosed(t, again)

	if st := h.s.Status(); st.Splices != 1 || st.PendingTickets != 0 {
		t.Fatalf("%+v", st)
	}
	client.Close()
	expectClosed(t, leg)
	waitFor(t, func() bool { return h.s.Status().Splices == 0 })
}

func TestSpliceHostSideCloses(t *testing.T) {
	h := start(t, fastLimits())
	key := newKey(t)
	hs := h.register(hostA, key, "")
	client, sent := h.client(hostA, nil)
	leg, a := h.accept(hs.incoming(t).Ticket, key)
	if !a.OK {
		t.Fatalf("%+v", a)
	}
	io.ReadFull(leg, make([]byte, len(sent)))
	leg.Close()
	expectClosed(t, client)
}

// The splice outlives the ticket's ten seconds.
func TestSpliceOutlivesTicket(t *testing.T) {
	l := fastLimits()
	l.TicketLife = 200 * time.Millisecond
	h := start(t, l)
	key := newKey(t)
	hs := h.register(hostA, key, "")
	client, sent := h.client(hostA, nil)
	leg, a := h.accept(hs.incoming(t).Ticket, key)
	if !a.OK {
		t.Fatalf("%+v", a)
	}
	io.ReadFull(leg, make([]byte, len(sent)))
	time.Sleep(400 * time.Millisecond)
	client.Write([]byte("still"))
	got := make([]byte, 5)
	if _, err := io.ReadFull(leg, got); err != nil || string(got) != "still" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestAcceptNeedsTheHostKey(t *testing.T) {
	h := start(t, fastLimits())
	key := newKey(t)
	hs := h.register(hostA, key, "")
	h.client(hostA, nil)
	ticket := hs.incoming(t).Ticket
	c, a := h.accept(ticket, newKey(t))
	if a.Reason != protocol.ReasonTicket {
		t.Fatalf("%+v", a)
	}
	expectClosed(t, c)
	// A forged accept does not use the ticket up.
	if _, a := h.accept(ticket, key); !a.OK {
		t.Fatalf("%+v", a)
	}
}

func TestTicketExpires(t *testing.T) {
	l := fastLimits()
	l.TicketLife = 200 * time.Millisecond
	h := start(t, l)
	key := newKey(t)
	hs := h.register(hostA, key, "")
	client, _ := h.client(hostA, nil)
	ticket := hs.incoming(t).Ticket
	expectClosed(t, client)
	if _, a := h.accept(ticket, key); a.Reason != protocol.ReasonTicket {
		t.Fatalf("%+v", a)
	}
	if st := h.s.Status(); st.Splices != 0 || st.PendingTickets != 0 {
		t.Fatalf("%+v", st)
	}
}

func TestTicketDiesWithClient(t *testing.T) {
	h := start(t, fastLimits())
	key := newKey(t)
	hs := h.register(hostA, key, "")
	client, _ := h.client(hostA, nil)
	ticket := hs.incoming(t).Ticket
	client.Close()
	waitFor(t, func() bool { return h.s.Status().PendingTickets == 0 })
	if _, a := h.accept(ticket, key); a.Reason != protocol.ReasonTicket {
		t.Fatalf("%+v", a)
	}
}

func TestTicketDiesWithHost(t *testing.T) {
	h := start(t, fastLimits())
	hs := h.register(hostA, newKey(t), "")
	client, _ := h.client(hostA, nil)
	hs.incoming(t)
	hs.conn.Close()
	expectClosed(t, client)
}

func TestNoSuchHost(t *testing.T) {
	h := start(t, fastLimits())
	client, _ := h.client(hostB, nil)
	expectClosed(t, client)
	other := h.dial()
	other.Write(testhello.Hello("relay.example.com"))
	expectClosed(t, other)
}

func TestHostLimit(t *testing.T) {
	l := fastLimits()
	l.Hosts = 1
	h := start(t, l)
	key := newKey(t)
	h.register(hostA, key, "")
	h.register(hostB, newKey(t), protocol.ReasonFull)
	// Replacing a registered host is not a new one.
	h.register(hostA, key, "")
}

func TestTicketsPerHost(t *testing.T) {
	l := fastLimits()
	l.TicketsPerHost = 2
	h := start(t, l)
	hs := h.register(hostA, newKey(t), "")
	h.client(hostA, nil)
	h.client(hostA, nil)
	hs.incoming(t)
	hs.incoming(t)
	third, _ := h.client(hostA, nil)
	expectClosed(t, third)
}

func TestSpliceLimit(t *testing.T) {
	l := fastLimits()
	l.Splices = 1
	h := start(t, l)
	key := newKey(t)
	hs := h.register(hostA, key, "")
	h.client(hostA, nil)
	leg, a := h.accept(hs.incoming(t).Ticket, key)
	if !a.OK {
		t.Fatal(a)
	}
	_ = leg
	second, _ := h.client(hostA, nil)
	expectClosed(t, second)
}

func TestPreSNILimit(t *testing.T) {
	l := fastLimits()
	l.PreSNI = 2
	h := start(t, l)
	a, b := h.dial(), h.dial()
	a.Write([]byte{0x16})
	b.Write([]byte{0x16})
	waitFor(t, func() bool { h.s.mu.Lock(); defer h.s.mu.Unlock(); return h.s.preSNI == 2 })
	third := h.dial()
	start := time.Now()
	expectClosed(t, third)
	if time.Since(start) > time.Second {
		t.Fatal("the connection over the limit waited for the handshake timeout")
	}
	a.Close()
	waitFor(t, func() bool { h.s.mu.Lock(); defer h.s.mu.Unlock(); return h.s.preSNI == 1 })
	hs := h.register(hostA, newKey(t), "")
	h.client(hostA, nil)
	hs.incoming(t)
}

func TestRateLimitPerAddress(t *testing.T) {
	l := fastLimits()
	l.RatePerIP = 3
	l.RateWindow = time.Minute
	h := start(t, l)
	hs := h.register(hostA, newKey(t), "")
	for range 3 {
		h.client(hostA, nil)
		hs.incoming(t)
	}
	fourth, _ := h.client(hostA, nil)
	expectClosed(t, fourth)
	// Control connections are not data connections.
	if l := h.list(); !l.OK {
		t.Fatal(l)
	}
}

func TestRateLimiterWindow(t *testing.T) {
	r := newRateLimiter(2, time.Second)
	ip := remoteIP(fakeAddrConn("192.0.2.1:5"))
	other := remoteIP(fakeAddrConn("192.0.2.2:5"))
	now := time.Unix(1000, 0)
	if !r.allow(ip, now) || !r.allow(ip, now) || r.allow(ip, now) {
		t.Fatal("the third connection in a window was allowed")
	}
	if !r.allow(other, now) {
		t.Fatal("another address shares the budget")
	}
	if !r.allow(ip, now.Add(1001*time.Millisecond)) {
		t.Fatal("the window did not move")
	}
}

func TestRateLimiterOff(t *testing.T) {
	r := newRateLimiter(0, time.Second)
	ip := remoteIP(fakeAddrConn("192.0.2.1:5"))
	now := time.Unix(1000, 0)
	for i := 0; i < 1000; i++ {
		if !r.allow(ip, now) {
			t.Fatal("a limit of 0 refused a connection")
		}
	}
}

func TestPendingBytesBound(t *testing.T) {
	l := fastLimits()
	l.PendingBytes = 1024
	h := start(t, l)
	hs := h.register(hostA, newKey(t), "")
	client, _ := h.client(hostA, nil)
	hs.incoming(t)
	client.Write(make([]byte, 4096))
	expectClosed(t, client)
}

func TestRotateDropsHosts(t *testing.T) {
	h := start(t, fastLimits())
	oldMember, oldID := h.member, h.id
	first := newKey(t)
	hs := h.register(hostA, first, "")
	if _, err := h.s.Rotate(); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, hs.conn)

	h.loadMember()
	if h.id != oldID {
		t.Fatal("rotate changed the relay id")
	}
	if h.member.Equal(oldMember) {
		t.Fatal("rotate kept the key")
	}
	// The old configuration is refused...
	c, hello := h.control(protocol.Version)
	send(t, c, protocol.Request{Role: protocol.RoleList,
		Sig: sign(t, oldMember, protocol.SignedMessage(protocol.RoleList, h.id, hello.Nonce, ""))})
	if a := answer(t, c); a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}
	// ...the new one works, and bindings outlive the rotation.
	h.register(hostA, newKey(t), protocol.ReasonHostKey)
	h.register(hostA, first, "")
	r, _ := h.dir.LoadRelay()
	cfg, _ := h.dir.LoadConfig()
	if !store.Matches(cfg, r) {
		t.Fatal("relay.json and the configuration disagree after rotate")
	}
}

func TestAdminSocket(t *testing.T) {
	h := start(t, fastLimits())
	path := filepath.Join(t.TempDir(), "admin.sock")
	ln, err := h.s.ListenAdmin(path)
	if err != nil {
		t.Fatal(err)
	}
	go h.s.ServeAdmin(ln)
	h.register(hostA, newKey(t), "")
	resp, err := Admin(path, AdminRequest{Command: "status"})
	if err != nil || !resp.OK || resp.Status == nil || len(resp.Status.Hosts) != 1 || resp.Status.Endpoint != testEndpoint {
		t.Fatalf("%+v %v", resp, err)
	}
	if resp, _ := Admin(path, AdminRequest{Command: "forget", HostID: "nope"}); resp.OK {
		t.Fatal("forget accepted a non-uuid")
	}
	if resp, _ := Admin(path, AdminRequest{Command: "rotate"}); !resp.OK {
		t.Fatalf("%+v", resp)
	}
}

func TestEndpointChangeRewritesWithSameKey(t *testing.T) {
	dir := store.Dir(t.TempDir())
	h := startIn(t, dir, fastLimits())
	key := h.member
	h.s.Close()

	s, err := New(Options{Dir: dir, Name: "renamed", Version: "test",
		Endpoint: func() (string, string, error) { return "[2001:db8::7]:46405", "test", nil },
		Logger:   log.New(io.Discard, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	c, _ := dir.LoadConfig()
	got, _ := protocol.ParsePrivateKey(c.Key)
	if c.Endpoint != "[2001:db8::7]:46405" || c.Name != "renamed" || !got.Equal(key) {
		t.Fatalf("%+v", c)
	}
}

func TestDeletedConfigurationIsNotRegenerated(t *testing.T) {
	dir := store.Dir(t.TempDir())
	h := startIn(t, dir, fastLimits())
	member, id := h.member, h.id
	h.s.Close()
	os.Remove(dir.ConfigPath())

	logs := &syncBuffer{}
	s, err := New(Options{Dir: dir, Name: "test relay", Version: "test",
		Endpoint: func() (string, string, error) { return testEndpoint, "test", nil },
		Limits:   fastLimits(), Logger: log.New(logs, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir.ConfigPath()); !os.IsNotExist(err) {
		t.Fatal("a configuration came back without its key")
	}
	if !strings.Contains(logs.String(), "rotate") {
		t.Fatalf("the log does not point at rotate: %s", logs)
	}
	// Devices holding the old file still get in.
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	go s.Serve(ln)
	defer s.Close()
	h2 := &harness{t: t, s: s, addr: ln.Addr().String(), dir: dir, member: member, id: id}
	h2.register(hostA, newKey(t), "")
}

func TestNoEndpointWritesNothingThenRetries(t *testing.T) {
	dir := store.Dir(t.TempDir())
	var mu sync.Mutex
	fail := true
	logs := &syncBuffer{}
	s, err := New(Options{Dir: dir, Name: "r", Version: "test",
		Endpoint: func() (string, string, error) {
			mu.Lock()
			defer mu.Unlock()
			if fail {
				return "", "", errors.New("offline")
			}
			return testEndpoint, "test", nil
		},
		Limits: fastLimits(), Logger: log.New(logs, "", 0), RetryEndpoint: 50 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := os.Stat(dir.ConfigPath()); !os.IsNotExist(err) {
		t.Fatal("a configuration was written without an endpoint")
	}
	if !strings.Contains(logs.String(), "RELAY_PUBLIC_HOST") {
		t.Fatalf("the log does not name RELAY_PUBLIC_HOST: %s", logs)
	}
	// It serves meanwhile: a list is refused as unauthenticated, not dropped.
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	go s.Serve(ln)
	h := &harness{t: t, s: s, addr: ln.Addr().String(), dir: dir, member: newKey(t)}
	c, _ := h.control(protocol.Version)
	send(t, c, protocol.Request{Role: protocol.RoleList, Sig: "AAAA"})
	if a := answer(t, c); a.Reason != protocol.ReasonAuth {
		t.Fatalf("%+v", a)
	}

	mu.Lock()
	fail = false
	mu.Unlock()
	waitFor(t, func() bool { return s.Status().RelayID != "" })
	h.loadMember()
	h.register(hostA, newKey(t), "")
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type addrConn struct {
	net.Conn
	addr net.Addr
}

func (c addrConn) RemoteAddr() net.Addr { return c.addr }

func fakeAddrConn(s string) net.Conn {
	a, _ := net.ResolveTCPAddr("tcp", s)
	return addrConn{addr: a}
}
