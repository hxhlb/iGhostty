// Package clienthello reads the one TLS record a data connection opens with
// and finds the host id in its SNI. It parses only as far as the
// server_name extension and trusts nothing it reads: every length is checked
// against what is left before it is used.
package clienthello

import (
	"encoding/binary"
	"errors"
	"io"
	"strings"
)

// MaxRecord is the largest record body TLS allows (2^14), and the most the
// relay reads before it knows where a connection goes.
const MaxRecord = 16384

const (
	recordHandshake  = 0x16
	handshakeHello   = 0x01
	extServerName    = 0x0000
	nameTypeHostName = 0x00
)

var (
	ErrNotHandshake = errors.New("not a TLS handshake record")
	ErrRecordSize   = errors.New("record length out of range")
	ErrNotHello     = errors.New("not a ClientHello")
	ErrSpansRecords = errors.New("ClientHello does not fit its record")
	ErrMalformed    = errors.New("malformed ClientHello")
	ErrNoSNI        = errors.New("no server name")
	ErrManyNames    = errors.New("more than one server name")
	ErrNotHostID    = errors.New("server name is not a host id")
)

// ReadRecord reads one whole TLS record — a 5-byte header, then at most
// MaxRecord bytes — and returns it, header included, so the caller can hand
// the very bytes it read to the host.
func ReadRecord(r io.Reader) ([]byte, error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	if header[0] != recordHandshake {
		return nil, ErrNotHandshake
	}
	n := int(binary.BigEndian.Uint16(header[3:5]))
	if n == 0 || n > MaxRecord {
		return nil, ErrRecordSize
	}
	record := make([]byte, 5+n)
	copy(record, header)
	if _, err := io.ReadFull(r, record[5:]); err != nil {
		return nil, err
	}
	return record, nil
}

// HostID returns the lower-case host id a record's ClientHello names: one
// host_name, its trailing dot removed, a UUID.
func HostID(record []byte) (string, error) {
	if len(record) < 5 || record[0] != recordHandshake {
		return "", ErrNotHandshake
	}
	body := record[5:]
	if int(binary.BigEndian.Uint16(record[3:5])) != len(body) || len(body) > MaxRecord {
		return "", ErrRecordSize
	}
	if len(body) < 4 || body[0] != handshakeHello {
		return "", ErrNotHello
	}
	n := int(body[1])<<16 | int(body[2])<<8 | int(body[3])
	if n > len(body)-4 {
		return "", ErrSpansRecords
	}
	name, err := serverName(body[4 : 4+n])
	if err != nil {
		return "", err
	}
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	if !IsUUID(name) {
		return "", ErrNotHostID
	}
	return name, nil
}

// reader walks a byte slice; any read past the end sets bad and returns
// zeroes, so a parse checks once at the end of each step.
type reader struct {
	b   []byte
	bad bool
}

func (r *reader) take(n int) []byte {
	if r.bad || n < 0 || n > len(r.b) {
		r.bad = true
		return nil
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

func (r *reader) u8() int {
	b := r.take(1)
	if b == nil {
		return 0
	}
	return int(b[0])
}

func (r *reader) u16() int {
	b := r.take(2)
	if b == nil {
		return 0
	}
	return int(binary.BigEndian.Uint16(b))
}

func serverName(hello []byte) (string, error) {
	r := &reader{b: hello}
	r.take(2)      // legacy_version
	r.take(32)     // random
	r.take(r.u8()) // session id
	suites := r.u16()
	if suites%2 != 0 {
		return "", ErrMalformed
	}
	r.take(suites)
	r.take(r.u8()) // compression methods
	if r.bad {
		return "", ErrMalformed
	}
	if len(r.b) == 0 {
		return "", ErrNoSNI
	}
	exts := &reader{b: r.take(r.u16())}
	if r.bad || len(r.b) != 0 {
		return "", ErrMalformed
	}
	var name string
	found := false
	for len(exts.b) > 0 {
		typ := exts.u16()
		data := exts.take(exts.u16())
		if exts.bad {
			return "", ErrMalformed
		}
		if typ != extServerName {
			continue
		}
		if found {
			return "", ErrManyNames
		}
		found = true
		list := &reader{b: data}
		names := &reader{b: list.take(list.u16())}
		if list.bad || len(list.b) != 0 {
			return "", ErrMalformed
		}
		hostNames := 0
		for len(names.b) > 0 {
			kind := names.u8()
			value := names.take(names.u16())
			if names.bad {
				return "", ErrMalformed
			}
			if kind == nameTypeHostName {
				hostNames++
				name = string(value)
			}
		}
		if hostNames > 1 {
			return "", ErrManyNames
		}
		if hostNames == 0 {
			return "", ErrNoSNI
		}
	}
	if !found {
		return "", ErrNoSNI
	}
	return name, nil
}

// IsUUID reports whether s is a UUID in its 8-4-4-4-12 hex spelling, either
// case.
func IsUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !('0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F') {
				return false
			}
		}
	}
	return true
}
