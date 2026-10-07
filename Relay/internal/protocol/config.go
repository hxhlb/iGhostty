package protocol

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/base64"
	"errors"
	"net"
	"strconv"
	"strings"
)

// ConfigFormat and ConfigVersion identify a `.vtrpsc`. The version is the
// file format's, not the protocol's.
const (
	ConfigFormat  = "ighostvt-relay"
	ConfigVersion = 1
)

// Config is the `.vtrpsc` people import. Key is the relay's P-256 private
// key as a raw 32-byte big-endian scalar, base64.
type Config struct {
	Format   string `json:"format"`
	Version  int    `json:"version"`
	Name     string `json:"name"`
	Endpoint string `json:"endpoint"`
	RelayID  string `json:"relayID"`
	Key      string `json:"key"`
}

// EncodePrivateKey writes the raw scalar the configuration carries.
func EncodePrivateKey(priv *ecdsa.PrivateKey) (string, error) {
	raw, err := priv.Bytes()
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// ParsePrivateKey reads the configuration's key.
func ParsePrivateKey(keyB64 string) (*ecdsa.PrivateKey, error) {
	raw, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return nil, err
	}
	if len(raw) != 32 {
		return nil, errors.New("the key is not 32 bytes")
	}
	return ecdsa.ParseRawPrivateKey(elliptic.P256(), raw)
}

// Endpoint joins a host and a port the way the configuration spells them:
// an IPv6 address bracketed, anything else as it is.
func Endpoint(host string, port int) string {
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	return net.JoinHostPort(host, strconv.Itoa(port))
}
