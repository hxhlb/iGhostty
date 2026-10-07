package relay

import (
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/clienthello"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
)

// hostConn is one registered host's control connection.
type hostConn struct {
	id         string // as the host spelled it
	key        string // lower-case: what an SNI names
	name       string
	appVersion string
	since      int64
	from       string
	pub        *ecdsa.PublicKey
	conn       net.Conn
	tickets    map[string]*splice // offered and not yet accepted

	wmu sync.Mutex
}

// send writes one frame; frames to a host come from several goroutines.
func (h *hostConn) send(m protocol.Message) error {
	h.wmu.Lock()
	defer h.wmu.Unlock()
	return h.writeLocked(m)
}

func (h *hostConn) writeLocked(v any) error {
	h.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return protocol.WriteFrame(h.conn, v)
}

const maxTextField = 1024

// handleControl speaks the control protocol. The first byte, `I`, is read.
func (s *Server) handleControl(conn net.Conn) {
	requested := false
	defer func() {
		if !requested {
			s.release(&s.preReq)
		}
	}()
	rest := make([]byte, len(protocol.Magic))
	if _, err := io.ReadFull(conn, rest); err != nil || string(rest[:3]) != protocol.Magic[1:] {
		conn.Close()
		return
	}
	version := rest[3]

	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic(err)
	}
	nonce := base64.StdEncoding.EncodeToString(raw[:])
	relayID := s.currentRelayID()
	hello := protocol.Hello{Relay: protocol.HelloRelay, Version: protocol.Version, RelayID: relayID, Nonce: nonce}
	if err := protocol.WriteFrame(conn, hello); err != nil {
		conn.Close()
		return
	}
	if version != protocol.Version {
		refuse(conn, protocol.ReasonVersion)
		return
	}

	body, err := protocol.ReadFrame(conn)
	if err != nil {
		conn.Close()
		return
	}
	requested = true
	s.release(&s.preReq)
	var req protocol.Request
	if err := json.Unmarshal(body, &req); err != nil {
		refuse(conn, protocol.ReasonInvalid)
		return
	}
	switch req.Role {
	case protocol.RoleHost:
		s.register(conn, relayID, nonce, req)
	case protocol.RoleAccept:
		s.accept(conn, req)
	case protocol.RoleList:
		s.list(conn, relayID, nonce, req)
	default:
		refuse(conn, protocol.ReasonInvalid)
	}
}

// refuse answers `{"ok":false}` and closes.
func refuse(conn net.Conn, reason string) {
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	protocol.WriteFrame(conn, protocol.Answer{OK: false, Reason: reason})
	conn.Close()
}

func validText(s string) bool {
	return len(s) <= maxTextField && utf8.ValidString(s)
}

// register admits a host: `sig` proves membership, `hostSig` the host key,
// and the first key a host id registers with is the only one it ever may.
func (s *Server) register(conn net.Conn, relayID, nonce string, req protocol.Request) {
	if !clienthello.IsUUID(req.HostID) || !validText(req.Name) || !validText(req.AppVersion) {
		refuse(conn, protocol.ReasonInvalid)
		return
	}
	message := protocol.SignedMessage(protocol.RoleHost, relayID, nonce, req.HostID)
	relayKey, gen := s.currentKey()
	if !protocol.Verify(relayKey, message, req.Sig) {
		refuse(conn, protocol.ReasonAuth)
		return
	}
	hostPub, err := protocol.ParsePublicKey(req.HostKey)
	if err != nil {
		refuse(conn, protocol.ReasonInvalid)
		return
	}
	if !protocol.Verify(hostPub, message, req.HostSig) {
		refuse(conn, protocol.ReasonHostKey)
		return
	}
	hostKey, _ := protocol.EncodePublicKey(hostPub) // canonical, whatever padding came in

	key := strings.ToLower(req.HostID)
	h := &hostConn{
		id:         req.HostID,
		key:        key,
		name:       req.Name,
		appVersion: req.AppVersion,
		since:      time.Now().Unix(),
		from:       remoteIP(conn).String(),
		pub:        hostPub,
		conn:       conn,
		tickets:    map[string]*splice{},
	}
	// Holding the new host's write lock across install and `ok` keeps an
	// `incoming` from reaching it before its answer.
	h.wmu.Lock()
	s.mu.Lock()
	reason := ""
	old := s.hosts[key]
	binding, bound := s.bindings[key]
	switch {
	case s.closed:
		reason = protocol.ReasonInvalid
	case gen != s.keyGen:
		reason = protocol.ReasonAuth
	case bound && binding.HostKey != hostKey:
		reason = protocol.ReasonHostKey
	case old == nil && len(s.hosts) >= s.limits.Hosts:
		reason = protocol.ReasonFull
	}
	if reason == "" && !bound {
		s.bindings[key] = store.Binding{HostKey: hostKey, BoundAt: h.since}
		if err := s.opts.Dir.SaveBindings(s.bindings); err != nil {
			delete(s.bindings, key)
			s.log.Printf("could not save the host bindings: %v", err)
			reason = protocol.ReasonInvalid
		}
	}
	if reason == "" {
		s.hosts[key] = h
	}
	s.mu.Unlock()
	if reason != "" {
		h.wmu.Unlock()
		refuse(conn, reason)
		return
	}
	err = h.writeLocked(protocol.Answer{OK: true})
	h.wmu.Unlock()
	if old != nil {
		old.send(protocol.Message{Type: "superseded"})
		s.dropHost(old)
		s.log.Printf("host %s registered again from %s; the earlier connection was told it is superseded", key, h.from)
	} else {
		s.log.Printf("host %s (%q, %s) registered from %s", key, h.name, h.appVersion, h.from)
	}
	if err != nil {
		s.dropHost(h)
		return
	}
	s.serveHost(h)
}

// serveHost reads a registered host until it goes quiet or away.
func (s *Server) serveHost(h *hostConn) {
	defer s.dropHost(h)
	h.conn.SetDeadline(time.Time{})
	for {
		h.conn.SetReadDeadline(time.Now().Add(s.limits.HostSilence))
		body, err := protocol.ReadFrame(h.conn)
		if err != nil {
			return
		}
		var m protocol.Message
		if json.Unmarshal(body, &m) != nil {
			continue
		}
		if m.Type == "ping" {
			if h.send(protocol.Message{Type: "pong"}) != nil {
				return
			}
		}
	}
}

// dropHost forgets a registration, if it is still the current one, closes
// it, and ends every ticket it was offered.
func (s *Server) dropHost(h *hostConn) {
	s.mu.Lock()
	current := s.hosts[h.key] == h
	if current {
		delete(s.hosts, h.key)
	}
	offered := make([]*splice, 0, len(h.tickets))
	for _, sp := range h.tickets {
		offered = append(offered, sp)
	}
	s.mu.Unlock()
	h.conn.Close()
	for _, sp := range offered {
		sp.finish()
	}
	if current {
		s.log.Printf("host %s dropped", h.key)
	}
}

// accept hands a ticket's client to the connection that accepts it.
func (s *Server) accept(conn net.Conn, req protocol.Request) {
	if req.Ticket == "" || req.HostSig == "" {
		refuse(conn, protocol.ReasonInvalid)
		return
	}
	sp := s.claim(req.Ticket, req.HostSig)
	if sp == nil || !sp.attach(conn) {
		if sp != nil {
			sp.finish()
		}
		refuse(conn, protocol.ReasonTicket)
	}
}

// list answers the hosts online, for a member.
func (s *Server) list(conn net.Conn, relayID, nonce string, req protocol.Request) {
	relayKey, _ := s.currentKey()
	if !protocol.Verify(relayKey, protocol.SignedMessage(protocol.RoleList, relayID, nonce, ""), req.Sig) {
		refuse(conn, protocol.ReasonAuth)
		return
	}
	answer := protocol.ListAnswer{OK: true, Hosts: s.onlineHosts()}
	conn.SetWriteDeadline(time.Now().Add(s.limits.WriteTimeout))
	protocol.WriteFrame(conn, answer)
	conn.Close()
}

func (s *Server) onlineHosts() []protocol.HostInfo {
	s.mu.Lock()
	hosts := make([]protocol.HostInfo, 0, len(s.hosts))
	for _, h := range s.hosts {
		hosts = append(hosts, protocol.HostInfo{ID: h.id, Name: h.name, AppVersion: h.appVersion, Since: h.since})
	}
	s.mu.Unlock()
	sort.Slice(hosts, func(i, j int) bool {
		if hosts[i].Name != hosts[j].Name {
			return hosts[i].Name < hosts[j].Name
		}
		return hosts[i].ID < hosts[j].ID
	})
	return hosts
}
