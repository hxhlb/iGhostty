package relay

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"io"
	"net"
	"sync"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/clienthello"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
)

const copyBuffer = 32 * 1024

// splice is one app connection from its ClientHello on: first a ticket
// waiting for the host's accept, then the two legs copied both ways. It holds
// one of the Splices slots for its whole life, and finish gives it back
// exactly once, however it ends.
type splice struct {
	s      *Server
	ticket string
	host   *hostConn // the registration the ticket was offered to
	client net.Conn
	timer  *time.Timer

	mu      sync.Mutex
	pending []byte   // client bytes read before the accept
	leg     net.Conn // the host's accepted connection, once there is one
	done    bool

	once sync.Once
}

func (s *Server) handleData(conn net.Conn, first byte) {
	if !s.rate.allow(remoteIP(conn), time.Now()) {
		s.release(&s.preSNI)
		conn.Close()
		return
	}
	record, err := clienthello.ReadRecord(io.MultiReader(bytes.NewReader([]byte{first}), conn))
	var id string
	if err == nil {
		id, err = clienthello.HostID(record)
	}
	s.release(&s.preSNI)
	if err != nil {
		conn.Close()
		return
	}

	ticket := newTicket()
	sp := &splice{s: s, ticket: ticket, client: conn, pending: record}
	s.mu.Lock()
	h := s.hosts[id]
	if h == nil || len(h.tickets) >= s.limits.TicketsPerHost || s.splices >= s.limits.Splices || s.closed {
		s.mu.Unlock()
		conn.Close()
		return
	}
	sp.host = h
	s.splices++
	s.tickets[ticket] = sp
	h.tickets[ticket] = sp
	sp.timer = time.AfterFunc(s.limits.TicketLife, sp.finish)
	s.mu.Unlock()

	conn.SetDeadline(time.Time{})
	go sp.readClient()
	from := ""
	if ip := remoteIP(conn); ip.IsValid() {
		from = ip.String()
	}
	if err := h.send(protocol.Message{Type: "incoming", Ticket: ticket, From: from}); err != nil {
		s.dropHost(h)
	}
}

func newTicket() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// readClient is the client→host half. Before the accept it only holds what
// arrives (and notices the client leaving, which kills the ticket); after,
// it writes each read to the host before reading again.
func (sp *splice) readClient() {
	defer sp.finish()
	buf := make([]byte, copyBuffer)
	for {
		n, err := sp.client.Read(buf)
		if n > 0 {
			sp.mu.Lock()
			leg := sp.leg
			if leg == nil {
				if len(sp.pending)+n > sp.s.limits.PendingBytes {
					sp.mu.Unlock()
					return
				}
				sp.pending = append(sp.pending, buf[:n]...)
			}
			sp.mu.Unlock()
			if leg != nil {
				if _, werr := leg.Write(buf[:n]); werr != nil {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}

// attach takes the host's accepted connection: it writes the `ok` frame and
// every client byte held so far, in that order, then starts the host→client
// half. False means the client went first; the caller answers `ticket`.
func (sp *splice) attach(leg net.Conn) bool {
	sp.mu.Lock()
	defer sp.mu.Unlock()
	if sp.done {
		return false
	}
	ok, _ := protocol.EncodeFrame(protocol.Answer{OK: true})
	leg.SetWriteDeadline(time.Now().Add(sp.s.limits.WriteTimeout))
	if _, err := leg.Write(append(ok, sp.pending...)); err != nil {
		sp.leg = leg // finish closes it
		go sp.finish()
		return true
	}
	leg.SetDeadline(time.Time{})
	sp.pending = nil
	sp.leg = leg
	go func() {
		defer sp.finish()
		io.CopyBuffer(sp.client, onlyReader{leg}, make([]byte, copyBuffer))
	}()
	return true
}

// onlyReader hides the connection's WriterTo/ReaderFrom so the copy is the
// plain read-then-write loop with its fixed buffer.
type onlyReader struct{ io.Reader }

// finish ends the splice: forgets the ticket if it is still offered, closes
// both legs, and frees the slot. Safe from any goroutine, any number of times.
func (sp *splice) finish() {
	sp.once.Do(func() {
		s := sp.s
		s.mu.Lock()
		if s.tickets[sp.ticket] == sp {
			delete(s.tickets, sp.ticket)
		}
		delete(sp.host.tickets, sp.ticket)
		s.splices--
		s.mu.Unlock()
		sp.timer.Stop()
		sp.mu.Lock()
		sp.done = true
		leg := sp.leg
		sp.mu.Unlock()
		sp.client.Close()
		if leg != nil {
			leg.Close()
		}
	})
}

// claim takes an offered ticket for an accept whose signature checks with
// the host key it was offered to, so a ticket is used once.
func (s *Server) claim(ticket, hostSig string) *splice {
	s.mu.Lock()
	sp := s.tickets[ticket]
	s.mu.Unlock()
	if sp == nil {
		return nil
	}
	message := protocol.SignedMessage(protocol.RoleAccept, s.currentRelayID(), "", ticket)
	if !protocol.Verify(sp.host.pub, message, hostSig) {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tickets[ticket] != sp {
		return nil
	}
	delete(s.tickets, ticket)
	delete(sp.host.tickets, ticket)
	// From here the splice lives as long as its legs do. A timer that has
	// already fired is finishing it, and attach will find it done.
	sp.timer.Stop()
	return sp
}
