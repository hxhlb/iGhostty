package publicip

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
)

func fixed(name, addr string) Source {
	return Source{Name: name, Lookup: func(context.Context) (netip.Addr, error) {
		return netip.ParseAddr(addr)
	}}
}

func failing(name string) Source {
	return Source{Name: name, Lookup: func(context.Context) (netip.Addr, error) {
		return netip.Addr{}, errors.New("unreachable")
	}}
}

func TestDetect(t *testing.T) {
	cases := []struct {
		name     string
		sources  []Source
		want     string
		source   string
		warnings int
		fails    bool
	}{
		{"both agree", []Source{fixed("Cloudflare", "203.0.113.7"), fixed("Google", "203.0.113.7")}, "203.0.113.7", "Cloudflare", 0, false},
		{"first fails", []Source{failing("Cloudflare"), fixed("Google", "203.0.113.7")}, "203.0.113.7", "Google", 0, false},
		{"second fails", []Source{fixed("Cloudflare", "203.0.113.7"), failing("Google")}, "203.0.113.7", "Cloudflare", 0, false},
		{"disagree: Cloudflare wins", []Source{fixed("Cloudflare", "203.0.113.7"), fixed("Google", "198.51.100.9")}, "203.0.113.7", "Cloudflare", 1, false},
		{"IPv4 over IPv6", []Source{fixed("Cloudflare", "2001:db8::7"), fixed("Google", "198.51.100.9")}, "198.51.100.9", "Google", 0, false},
		{"IPv6 only", []Source{fixed("Cloudflare", "2001:db8::7"), failing("Google")}, "2001:db8::7", "Cloudflare", 0, false},
		{"mapped IPv4 unmapped", []Source{fixed("Cloudflare", "::ffff:203.0.113.7")}, "203.0.113.7", "Cloudflare", 0, false},
		{"private is not an answer", []Source{fixed("Cloudflare", "192.168.1.2"), failing("Google")}, "", "", 0, true},
		{"both fail", []Source{failing("Cloudflare"), failing("Google")}, "", "", 0, true},
	}
	for _, c := range cases {
		got, err := Detect(context.Background(), c.sources)
		if c.fails {
			if err == nil {
				t.Errorf("%s: got %v, want an error", c.name, got.Addr)
			}
			continue
		}
		if err != nil || got.Addr.String() != c.want || got.Source != c.source || len(got.Warnings) != c.warnings {
			t.Errorf("%s: got %v from %s (%d warnings), %v", c.name, got.Addr, got.Source, len(got.Warnings), err)
		}
	}
}

func TestEndpointBracketsIPv6(t *testing.T) {
	cases := map[string]string{
		"2001:db8::7":       "[2001:db8::7]:46405",
		"[2001:db8::7]":     "[2001:db8::7]:46405",
		"203.0.113.7":       "203.0.113.7:46405",
		"relay.example.com": "relay.example.com:46405",
	}
	for host, want := range cases {
		if got := protocol.Endpoint(host, 46405); got != want {
			t.Errorf("%s: got %s, want %s", host, got, want)
		}
	}
}

func TestDetectTimesOut(t *testing.T) {
	hang := Source{Name: "slow", Lookup: func(ctx context.Context) (netip.Addr, error) {
		<-ctx.Done()
		return netip.Addr{}, ctx.Err()
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := Detect(ctx, []Source{hang}); err == nil {
		t.Fatal("a hung source answered")
	}
}

func TestCloudflare(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "fl=1\nh=1.1.1.1\nip=203.0.113.7\nts=1\nvisit_scheme=https\n")
	}))
	defer srv.Close()
	addr, err := Cloudflare(srv.URL, srv.Client()).Lookup(context.Background())
	if err != nil || addr.String() != "203.0.113.7" {
		t.Fatalf("got %v, %v", addr, err)
	}

	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "fl=1\nh=1.1.1.1\n")
	}))
	defer bad.Close()
	if _, err := Cloudflare(bad.URL, bad.Client()).Lookup(context.Background()); err == nil {
		t.Fatal("a page without ip= answered")
	}

	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no", http.StatusServiceUnavailable)
	}))
	defer down.Close()
	if _, err := Cloudflare(down.URL, down.Client()).Lookup(context.Background()); err == nil {
		t.Fatal("a 503 answered")
	}
}

// fakeDNS answers every TXT question over UDP with one TXT string.
func fakeDNS(t *testing.T, txt string) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			q := buf[:n]
			// The question ends after the name's zero byte, then type and class.
			end := 12
			for end < len(q) && q[end] != 0 {
				end += int(q[end]) + 1
			}
			end += 5
			if end > len(q) {
				continue
			}
			resp := make([]byte, 0, 512)
			resp = append(resp, q[0], q[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0)
			resp = append(resp, q[12:end]...)
			rdata := append([]byte{byte(len(txt))}, txt...)
			resp = append(resp, 0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 60)
			resp = binary.BigEndian.AppendUint16(resp, uint16(len(rdata)))
			resp = append(resp, rdata...)
			pc.WriteTo(resp, from)
		}
	}()
	return pc.LocalAddr().String()
}

func TestGoogle(t *testing.T) {
	server := fakeDNS(t, "203.0.113.7")
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		if !strings.HasPrefix(network, "udp") {
			return nil, errors.New("udp only")
		}
		var d net.Dialer
		return d.DialContext(ctx, network, address)
	}
	addr, err := Google(server, "o-o.myaddr.l.google.com", dial).Lookup(context.Background())
	if err != nil || addr.String() != "203.0.113.7" {
		t.Fatalf("got %v, %v", addr, err)
	}

	junk := fakeDNS(t, "not an address")
	if _, err := Google(junk, "o-o.myaddr.l.google.com", dial).Lookup(context.Background()); err == nil {
		t.Fatal("a junk TXT answered")
	}
}
