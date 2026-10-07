package clienthello_test

import (
	"bytes"
	"errors"
	"io"
	"testing"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/clienthello"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/testhello"
)

const id = "6f1c2a7e-0b3d-4c5e-8f90-123456789abc"

func record(o testhello.Options) []byte {
	return testhello.Record(testhello.Handshake(testhello.Body(o)))
}

func TestHostID(t *testing.T) {
	cases := []struct {
		name   string
		record []byte
		want   string
		err    error
	}{
		{"lower case", testhello.Hello(id), id, nil},
		{"upper case", testhello.Hello("6F1C2A7E-0B3D-4C5E-8F90-123456789ABC"), id, nil},
		{"trailing dot", testhello.Hello(id + "."), id, nil},
		{"not a uuid", testhello.Hello("relay.example.com"), "", clienthello.ErrNotHostID},
		{"uuid without dashes", testhello.Hello("6f1c2a7e0b3d4c5e8f90123456789abc"), "", clienthello.ErrNotHostID},
		{"two dots", testhello.Hello(id + ".."), "", clienthello.ErrNotHostID},
		{"no sni", record(testhello.Options{}), "", clienthello.ErrNoSNI},
		{"no extensions", record(testhello.Options{NoExtensions: true}), "", clienthello.ErrNoSNI},
		{"empty name list", record(testhello.Options{Names: []string{}}), "", clienthello.ErrNoSNI},
		{"two names", record(testhello.Options{Names: []string{id, id}}), "", clienthello.ErrManyNames},
		{"two sni extensions", record(testhello.Options{Names: []string{id}, SecondSNI: true}), "", clienthello.ErrManyNames},
		{"not a hello", testhello.Record([]byte{0x02, 0, 0, 1, 0}), "", clienthello.ErrNotHello},
	}
	for _, c := range cases {
		got, err := clienthello.HostID(c.record)
		if got != c.want || !errors.Is(err, c.err) {
			t.Errorf("%s: got %q, %v; want %q, %v", c.name, got, err, c.want, c.err)
		}
	}
}

// A ClientHello longer than its record is one spread over several records.
func TestHostIDSpansRecords(t *testing.T) {
	handshake := testhello.Handshake(testhello.Body(testhello.Options{Names: []string{id}}))
	first := testhello.Record(handshake[:40])
	if _, err := clienthello.HostID(first); !errors.Is(err, clienthello.ErrSpansRecords) {
		t.Fatalf("got %v", err)
	}
	// Both records read back to back still parse as the first one alone.
	stream := append(first, testhello.Record(handshake[40:])...)
	rec, err := clienthello.ReadRecord(bytes.NewReader(stream))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := clienthello.HostID(rec); !errors.Is(err, clienthello.ErrSpansRecords) {
		t.Fatalf("got %v", err)
	}
}

func TestReadRecord(t *testing.T) {
	hello := testhello.Hello(id)
	rec, err := clienthello.ReadRecord(bytes.NewReader(append(hello, "after"...)))
	if err != nil || !bytes.Equal(rec, hello) {
		t.Fatalf("got %d bytes, %v", len(rec), err)
	}

	if _, err := clienthello.ReadRecord(bytes.NewReader(hello[:len(hello)-1])); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Errorf("truncated: %v", err)
	}
	oversize := []byte{0x16, 0x03, 0x01, 0x40, 0x01} // 16385
	if _, err := clienthello.ReadRecord(bytes.NewReader(oversize)); !errors.Is(err, clienthello.ErrRecordSize) {
		t.Errorf("oversize: %v", err)
	}
	empty := []byte{0x16, 0x03, 0x01, 0x00, 0x00}
	if _, err := clienthello.ReadRecord(bytes.NewReader(empty)); !errors.Is(err, clienthello.ErrRecordSize) {
		t.Errorf("empty: %v", err)
	}
	if _, err := clienthello.ReadRecord(bytes.NewReader([]byte{0x17, 3, 3, 0, 1, 0})); !errors.Is(err, clienthello.ErrNotHandshake) {
		t.Errorf("application data: %v", err)
	}
	max := append([]byte{0x16, 0x03, 0x01, 0x40, 0x00}, make([]byte, 16384)...)
	if _, err := clienthello.ReadRecord(bytes.NewReader(max)); err != nil {
		t.Errorf("16384 bytes: %v", err)
	}
}

// Every truncation of the hello inside a well-formed record must be refused
// without a panic: each length inside it then claims more than is there.
func TestHostIDTruncatedInside(t *testing.T) {
	body := testhello.Body(testhello.Options{Names: []string{id}})
	for n := 0; n < len(body); n++ {
		handshake := testhello.Handshake(body[:n])
		if got, err := clienthello.HostID(testhello.Record(handshake)); err == nil {
			t.Fatalf("truncated at %d parsed as %q", n, got)
		}
	}
}

func FuzzHostID(f *testing.F) {
	f.Add(testhello.Hello(id))
	f.Add(record(testhello.Options{Names: []string{id, id}}))
	f.Fuzz(func(t *testing.T, b []byte) {
		got, err := clienthello.HostID(b)
		if err == nil && !clienthello.IsUUID(got) {
			t.Fatalf("parsed %q", got)
		}
	})
}
