// Package publicip finds the address the relay's own traffic leaves from, for
// a configuration nobody gave a RELAY_PUBLIC_HOST. It asks two unrelated
// services — Cloudflare's trace over HTTPS and Google's authoritative DNS —
// and is only ever called when that variable is empty.
package publicip

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"
)

// Timeout bounds each source on its own.
const Timeout = 5 * time.Second

// Source is one way to learn the address.
type Source struct {
	Name   string
	Lookup func(ctx context.Context) (netip.Addr, error)
}

// Result is what Detect settled on.
type Result struct {
	Addr     netip.Addr
	Source   string
	Warnings []string
}

// Detect asks every source at once, each under Timeout, and chooses: an IPv4
// answer over an IPv6 one, and among equals the earlier source — the first
// is Cloudflare, which wins a disagreement. Every source failing is an error.
func Detect(ctx context.Context, sources []Source) (Result, error) {
	type answer struct {
		addr netip.Addr
		err  error
	}
	answers := make([]answer, len(sources))
	done := make(chan struct{})
	for i, source := range sources {
		go func() {
			defer func() { done <- struct{}{} }()
			c, cancel := context.WithTimeout(ctx, Timeout)
			defer cancel()
			addr, err := source.Lookup(c)
			if err == nil && !isPublic(addr) {
				err = fmt.Errorf("answered %s, which is not a public address", addr)
			}
			answers[i] = answer{addr.Unmap(), err}
		}()
	}
	for range sources {
		<-done
	}

	var result Result
	var failures []string
	chosen := -1
	for i, a := range answers {
		if a.err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", sources[i].Name, a.err))
			continue
		}
		if chosen < 0 || (!answers[chosen].addr.Is4() && a.addr.Is4()) {
			chosen = i
		}
	}
	if chosen < 0 {
		return result, errors.New(strings.Join(failures, "; "))
	}
	result.Addr = answers[chosen].addr
	result.Source = sources[chosen].Name
	for i, a := range answers {
		if a.err == nil && i != chosen && a.addr.Is4() == result.Addr.Is4() && a.addr != result.Addr {
			result.Warnings = append(result.Warnings, fmt.Sprintf(
				"%s says %s but %s says %s; using %s's", result.Source, result.Addr, sources[i].Name, a.addr, result.Source))
		}
	}
	return result, nil
}

func isPublic(a netip.Addr) bool {
	a = a.Unmap()
	return a.IsValid() && a.IsGlobalUnicast() && !a.IsPrivate()
}

// Default is the production pair, Cloudflare first.
func Default() []Source {
	return []Source{
		Cloudflare("https://1.1.1.1/cdn-cgi/trace", nil),
		Google("ns1.google.com", "o-o.myaddr.l.google.com", nil),
	}
}

// Cloudflare reads the `ip=` line of a `/cdn-cgi/trace` page. client nil
// means a plain client; tests pass their own.
func Cloudflare(url string, client *http.Client) Source {
	if client == nil {
		client = &http.Client{}
	}
	return Source{Name: "Cloudflare", Lookup: func(ctx context.Context) (netip.Addr, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return netip.Addr{}, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return netip.Addr{}, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return netip.Addr{}, fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		scanner := bufio.NewScanner(http.MaxBytesReader(nil, resp.Body, 16*1024))
		for scanner.Scan() {
			if value, ok := strings.CutPrefix(scanner.Text(), "ip="); ok {
				return netip.ParseAddr(strings.TrimSpace(value))
			}
		}
		if err := scanner.Err(); err != nil {
			return netip.Addr{}, err
		}
		return netip.Addr{}, errors.New("no ip= line")
	}}
}

// Google asks server (resolved by the system first, port 53 unless given)
// for name's TXT record, which Google's own servers answer with the address
// the question came from. dial nil dials for real; tests pass a fake.
func Google(server, name string, dial func(ctx context.Context, network, address string) (net.Conn, error)) Source {
	if dial == nil {
		var d net.Dialer
		dial = d.DialContext
	}
	return Source{Name: "Google", Lookup: func(ctx context.Context) (netip.Addr, error) {
		addresses, err := serverAddresses(ctx, server)
		if err != nil {
			return netip.Addr{}, err
		}
		var lastErr error
		for _, address := range addresses {
			resolver := &net.Resolver{
				PreferGo: true,
				Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
					return dial(ctx, network, address)
				},
			}
			records, err := resolver.LookupTXT(ctx, name)
			if err != nil {
				lastErr = err
				continue
			}
			for _, record := range records {
				if addr, err := netip.ParseAddr(strings.TrimSpace(record)); err == nil {
					return addr, nil
				}
			}
			lastErr = errors.New("no address in the TXT answer")
		}
		return netip.Addr{}, lastErr
	}}
}

// serverAddresses resolves the DNS server to dial, IPv4 addresses first.
func serverAddresses(ctx context.Context, server string) ([]string, error) {
	host, port, err := net.SplitHostPort(server)
	if err != nil {
		host, port = server, "53"
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		return []string{net.JoinHostPort(addr.String(), port)}, nil
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	var v4, v6 []string
	for _, ip := range ips {
		if ip.Unmap().Is4() {
			v4 = append(v4, net.JoinHostPort(ip.Unmap().String(), port))
		} else {
			v6 = append(v6, net.JoinHostPort(ip.String(), port))
		}
	}
	return append(v4, v6...), nil
}
