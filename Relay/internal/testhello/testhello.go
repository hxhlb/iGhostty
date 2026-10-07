// Package testhello builds TLS ClientHello records by hand for the tests:
// the relay only ever reads the record layer and the server_name extension,
// so no TLS stack is needed to exercise it.
package testhello

import "encoding/binary"

// Options shape one ClientHello.
type Options struct {
	// Names are the host_name entries of one server_name extension; nil
	// leaves the extension out.
	Names []string
	// SecondSNI adds a second server_name extension naming the same names.
	SecondSNI bool
	// NoExtensions leaves the extensions block out entirely.
	NoExtensions bool
}

func u16(n int) []byte { return binary.BigEndian.AppendUint16(nil, uint16(n)) }

func sni(names []string) []byte {
	var list []byte
	for _, n := range names {
		list = append(list, 0)
		list = append(list, u16(len(n))...)
		list = append(list, n...)
	}
	data := append(u16(len(list)), list...)
	return append(append(u16(0), u16(len(data))...), data...)
}

// Body is the ClientHello handshake body (no handshake header).
func Body(o Options) []byte {
	b := []byte{0x03, 0x03}
	b = append(b, make([]byte, 32)...)          // random
	b = append(b, 0)                            // session id
	b = append(b, 0, 4, 0xcc, 0xac, 0x00, 0xa8) // two suites
	b = append(b, 1, 0)                         // null compression
	if o.NoExtensions {
		return b
	}
	var exts []byte
	// supported_versions-ish filler, to make the walk skip something.
	exts = append(exts, 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x03)
	if o.Names != nil {
		exts = append(exts, sni(o.Names)...)
		if o.SecondSNI {
			exts = append(exts, sni(o.Names)...)
		}
	}
	exts = append(exts, 0xff, 0x01, 0x00, 0x01, 0x00) // renegotiation_info
	b = append(b, u16(len(exts))...)
	return append(b, exts...)
}

// Handshake wraps a body in its handshake header.
func Handshake(body []byte) []byte {
	n := len(body)
	return append([]byte{0x01, byte(n >> 16), byte(n >> 8), byte(n)}, body...)
}

// Record wraps handshake bytes in one TLS record.
func Record(handshake []byte) []byte {
	return append(append([]byte{0x16, 0x03, 0x01}, u16(len(handshake))...), handshake...)
}

// Hello is a whole one-record ClientHello naming host.
func Hello(host string) []byte {
	return Record(Handshake(Body(Options{Names: []string{host}})))
}
