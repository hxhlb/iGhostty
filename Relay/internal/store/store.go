// Package store owns the relay's data directory:
//
//	relay.json       the relay's public key, id and name — what it checks with
//	ighostvt.vtrpsc  the configuration people import, private key included;
//	                 written once per key, and the only copy of that key
//	hosts.json       host id → host key bindings (first registration wins)
//	admin.sock       where `rotate`, `forget` and `status` reach `serve`
//
// Every file is replaced by a rename, so a crash leaves the old one or the
// new one and never half of either.
package store

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
)

const (
	relayFile  = "relay.json"
	configFile = "ighostvt.vtrpsc"
	hostsFile  = "hosts.json"
	adminFile  = "admin.sock"
)

// Dir is a data directory.
type Dir string

func (d Dir) path(name string) string { return filepath.Join(string(d), name) }

// ConfigPath is where the configuration lives.
func (d Dir) ConfigPath() string { return d.path(configFile) }

// AdminSocket is the admin socket's path.
func (d Dir) AdminSocket() string { return d.path(adminFile) }

// Relay is relay.json: everything the relay keeps about its own key.
type Relay struct {
	RelayID   string `json:"relayID"`
	PublicKey string `json:"publicKey"` // SPKI DER, base64
	Name      string `json:"name"`
}

// Binding is one host id's host key.
type Binding struct {
	HostKey string `json:"hostKey"` // SPKI DER, base64
	BoundAt int64  `json:"boundAt"`
}

// LoadRelay reads relay.json; a missing file is (nil, nil).
func (d Dir) LoadRelay() (*Relay, error) {
	var r Relay
	ok, err := d.readJSON(relayFile, &r)
	if !ok || err != nil {
		return nil, err
	}
	if _, err := protocol.ParsePublicKey(r.PublicKey); err != nil {
		return nil, fmt.Errorf("%s: %w", relayFile, err)
	}
	return &r, nil
}

// SaveRelay writes relay.json.
func (d Dir) SaveRelay(r *Relay) error { return d.writeJSON(relayFile, r, 0o644) }

// LoadConfig reads the configuration; a missing file is (nil, nil).
func (d Dir) LoadConfig() (*protocol.Config, error) {
	var c protocol.Config
	ok, err := d.readJSON(configFile, &c)
	if !ok || err != nil {
		return nil, err
	}
	return &c, nil
}

// SaveConfig writes the configuration, readable by the relay's user only.
func (d Dir) SaveConfig(c *protocol.Config) error { return d.writeJSON(configFile, c, 0o600) }

// ConfigBytes is the configuration file exactly as it is on disk.
func (d Dir) ConfigBytes() ([]byte, error) { return os.ReadFile(d.ConfigPath()) }

// LoadBindings reads hosts.json, keyed by lower-case host id.
func (d Dir) LoadBindings() (map[string]Binding, error) {
	var file struct {
		Hosts map[string]Binding `json:"hosts"`
	}
	if _, err := d.readJSON(hostsFile, &file); err != nil {
		return nil, err
	}
	if file.Hosts == nil {
		file.Hosts = map[string]Binding{}
	}
	return file.Hosts, nil
}

// SaveBindings writes hosts.json.
func (d Dir) SaveBindings(bindings map[string]Binding) error {
	return d.writeJSON(hostsFile, struct {
		Hosts map[string]Binding `json:"hosts"`
	}{bindings}, 0o600)
}

// NewKey makes a relay key pair and the configuration that carries it.
// Nothing is written.
func NewKey(relayID, name, endpoint string) (*Relay, *protocol.Config, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	pub, err := protocol.EncodePublicKey(&priv.PublicKey)
	if err != nil {
		return nil, nil, err
	}
	key, err := protocol.EncodePrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}
	relay := &Relay{RelayID: relayID, PublicKey: pub, Name: name}
	config := &protocol.Config{
		Format:   protocol.ConfigFormat,
		Version:  protocol.ConfigVersion,
		Name:     name,
		Endpoint: endpoint,
		RelayID:  relayID,
		Key:      key,
	}
	return relay, config, nil
}

// Matches reports whether a configuration carries the private half of the
// relay's public key, for the same relay.
func Matches(c *protocol.Config, r *Relay) bool {
	if c == nil || r == nil || c.RelayID != r.RelayID {
		return false
	}
	priv, err := protocol.ParsePrivateKey(c.Key)
	if err != nil {
		return false
	}
	pub, err := protocol.EncodePublicKey(&priv.PublicKey)
	return err == nil && pub == r.PublicKey
}

// NewRelayID is a random UUID, upper-case, as Foundation spells one.
func NewRelayID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

func (d Dir) readJSON(name string, v any) (bool, error) {
	data, err := os.ReadFile(d.path(name))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(data, v); err != nil {
		return false, fmt.Errorf("%s: %w", name, err)
	}
	return true, nil
}

func (d Dir) writeJSON(name string, v any, mode os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(string(d), "."+name+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), d.path(name))
}
