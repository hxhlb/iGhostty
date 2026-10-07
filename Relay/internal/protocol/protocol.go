// Package protocol is the relay's wire vocabulary: the control magic, the
// length-prefixed JSON frames, the signed message, and the configuration
// file. Relay/PROTOCOL.md is the authority; this file only spells it in Go.
package protocol

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Version is the relay protocol's version: the byte after the magic and the
// `version` of the hello. It changes only when the control protocol does,
// never with an app release, and the image's major tag follows it.
const Version = 1

// Magic opens every control connection, followed by the Version byte.
const Magic = "IGVR"

// MaxFrame is the largest frame body either side accepts.
const MaxFrame = 64 * 1024

// Roles a control connection's first frame names.
const (
	RoleHost   = "host"
	RoleAccept = "accept"
	RoleList   = "list"
)

// Reasons an `{"ok":false}` answer carries.
const (
	ReasonVersion = "version"
	ReasonAuth    = "auth"
	ReasonHostKey = "hostKey"
	ReasonFull    = "full"
	ReasonInvalid = "invalid"
	ReasonTicket  = "ticket"
)

// Hello is the relay's first frame on every control connection.
type Hello struct {
	Relay   string `json:"relay"`
	Version int    `json:"version"`
	RelayID string `json:"relayID"`
	Nonce   string `json:"nonce"`
}

// HelloRelay is Hello.Relay's only value.
const HelloRelay = "ighostvt-relay"

// Request is the client's first frame; which fields matter depends on Role.
type Request struct {
	Role       string `json:"role"`
	HostID     string `json:"hostID,omitempty"`
	Name       string `json:"name,omitempty"`
	AppVersion string `json:"appVersion,omitempty"`
	HostKey    string `json:"hostKey,omitempty"`
	Sig        string `json:"sig,omitempty"`
	HostSig    string `json:"hostSig,omitempty"`
	Ticket     string `json:"ticket,omitempty"`
}

// Answer is the relay's reply to a Request.
type Answer struct {
	OK     bool   `json:"ok"`
	Reason string `json:"reason,omitempty"`
}

// ListAnswer is the reply to a member's `list`; Hosts is never null.
type ListAnswer struct {
	OK    bool       `json:"ok"`
	Hosts []HostInfo `json:"hosts"`
}

// HostInfo is one row of a `list` answer.
type HostInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	AppVersion string `json:"appVersion"`
	Since      int64  `json:"since"`
}

// Message is a frame on a registered host's connection: `ping`, `pong`,
// `incoming`, `superseded`.
type Message struct {
	Type   string `json:"type"`
	Ticket string `json:"ticket,omitempty"`
	From   string `json:"from,omitempty"`
}

// ReadFrame reads exactly one frame: four bytes of length, then that many.
// It never reads past the frame, so what follows an accepted `accept` stays
// in the connection.
func ReadFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(header[:])
	if n == 0 || n > MaxFrame {
		return nil, fmt.Errorf("frame of %d bytes", n)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	return body, nil
}

// EncodeFrame marshals v and prefixes its length.
func EncodeFrame(v any) ([]byte, error) {
	body, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	if len(body) > MaxFrame {
		return nil, fmt.Errorf("frame of %d bytes", len(body))
	}
	out := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(out, uint32(len(body)))
	copy(out[4:], body)
	return out, nil
}

// WriteFrame writes v as one frame in a single write.
func WriteFrame(w io.Writer, v any) error {
	frame, err := EncodeFrame(v)
	if err != nil {
		return err
	}
	_, err = w.Write(frame)
	return err
}

// SignedMessage is the text both `sig` and `hostSig` sign. The nonce is the
// hello's, exactly as it was sent; it is empty for `accept`.
func SignedMessage(role, relayID, nonce, param string) []byte {
	return []byte(strings.Join([]string{"ighostvt-relay-v1", role, relayID, nonce, param}, "\n"))
}

// Verify checks a base64 DER ECDSA signature over SHA-256 of message.
func Verify(pub *ecdsa.PublicKey, message []byte, sigB64 string) bool {
	if pub == nil || sigB64 == "" {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return false
	}
	digest := sha256.Sum256(message)
	return ecdsa.VerifyASN1(pub, digest[:], sig)
}

// ParsePublicKey reads a base64 SubjectPublicKeyInfo that must hold a P-256
// ECDSA key.
func ParsePublicKey(spkiB64 string) (*ecdsa.PublicKey, error) {
	der, err := base64.StdEncoding.DecodeString(spkiB64)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	pub, ok := key.(*ecdsa.PublicKey)
	if !ok || pub.Curve.Params().Name != "P-256" {
		return nil, errors.New("not a P-256 key")
	}
	return pub, nil
}

// EncodePublicKey is ParsePublicKey's inverse.
func EncodePublicKey(pub *ecdsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}
