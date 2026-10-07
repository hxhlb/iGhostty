package relay

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/clienthello"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
)

// SaveCommand is what the log tells people to run to get the configuration.
const SaveCommand = "docker compose exec relay ighostvt-relay config > relay.vtrpsc"

func (s *Server) currentKey() (*ecdsa.PublicKey, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.relayKey, s.keyGen
}

func (s *Server) currentRelayID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.relayID
}

func (s *Server) setKey(r *store.Relay) error {
	pub, err := protocol.ParsePublicKey(r.PublicKey)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.relayID = r.RelayID
	s.relayKey = pub
	s.mu.Unlock()
	return nil
}

// prepareKey loads the relay's key, recovers relay.json from a configuration
// that outlived it, and settles the endpoint. An endpoint that cannot be
// found is not fatal: the relay serves what it has and asks again later.
func (s *Server) prepareKey() error {
	s.keyMu.Lock()
	defer s.keyMu.Unlock()
	dir := s.opts.Dir
	relay, err := dir.LoadRelay()
	if err != nil {
		return err
	}
	config, err := dir.LoadConfig()
	if err != nil {
		s.log.Printf("warning: %s cannot be read (%v); it is left alone", dir.ConfigPath(), err)
		config = nil
	}
	if relay == nil && config != nil {
		if priv, err := protocol.ParsePrivateKey(config.Key); err == nil && clienthello.IsUUID(config.RelayID) {
			pub, _ := protocol.EncodePublicKey(&priv.PublicKey)
			relay = &store.Relay{RelayID: config.RelayID, PublicKey: pub, Name: config.Name}
			if err := dir.SaveRelay(relay); err != nil {
				return err
			}
			s.log.Printf("relay.json was missing; rebuilt it from the configuration")
		}
	}
	if relay != nil {
		if err := s.setKey(relay); err != nil {
			return err
		}
	}

	endpoint, how, err := s.opts.Endpoint()
	if err != nil {
		if relay == nil {
			s.log.Printf("could not find this server's public address (%v). No configuration was written. Set RELAY_PUBLIC_HOST to the domain or IP clients use and restart; until then the relay keeps asking", err)
		} else {
			s.log.Printf("warning: could not find this server's public address (%v); the configuration keeps its endpoint. Set RELAY_PUBLIC_HOST to stop guessing", err)
		}
		go s.retryEndpoint()
		return nil
	}
	return s.applyEndpointLocked(endpoint, how)
}

// retryEndpoint asks for the endpoint again, backing off, until it is found
// or the server closes: a relay that boots before its network is up should
// still end up with a configuration.
func (s *Server) retryEndpoint() {
	delay := s.opts.RetryEndpoint
	for {
		select {
		case <-s.stop:
			return
		case <-time.After(delay):
		}
		endpoint, how, err := s.opts.Endpoint()
		if err == nil {
			s.keyMu.Lock()
			err = s.applyEndpointLocked(endpoint, how)
			s.keyMu.Unlock()
			if err != nil {
				s.log.Printf("could not write the configuration: %v", err)
			}
			return
		}
		delay = min(delay*2, 10*time.Minute)
	}
}

// applyEndpointLocked writes the configuration for this endpoint: a new key
// on the first start, the same key under a new endpoint or name later.
func (s *Server) applyEndpointLocked(endpoint, how string) error {
	dir := s.opts.Dir
	name := s.opts.Name
	s.mu.Lock()
	s.endpoint = endpoint
	s.mu.Unlock()
	ready := fmt.Sprintf("ighostvt-relay %s (relay protocol %d): relay %q ready at %s (%s)",
		s.opts.Version, protocol.Version, name, endpoint, how)

	relay, err := dir.LoadRelay()
	if err != nil {
		return err
	}
	if relay == nil {
		r, c, err := store.NewKey(store.NewRelayID(), name, endpoint)
		if err != nil {
			return err
		}
		// The configuration first: a relay.json without it is a key nobody
		// can ever use, while the reverse is rebuilt at the next start.
		if err := dir.SaveConfig(c); err != nil {
			return err
		}
		if err := dir.SaveRelay(r); err != nil {
			return err
		}
		if err := s.setKey(r); err != nil {
			return err
		}
		s.log.Print(ready)
		s.log.Printf("ighostvt-relay: save the config with:\n    %s", SaveCommand)
		return nil
	}
	if relay.Name != name {
		relay.Name = name
		if err := dir.SaveRelay(relay); err != nil {
			return err
		}
	}

	config, err := dir.LoadConfig()
	switch {
	case err != nil:
		s.log.Print(ready)
		s.log.Printf("warning: %s cannot be read (%v)", dir.ConfigPath(), err)
	case config == nil:
		s.log.Print(ready)
		s.log.Printf("warning: %s was deleted, and with it the relay's private key. Devices that imported it keep working; "+
			"to set up another device, run `ighostvt-relay rotate`, which makes a new key — every device then imports the new file", dir.ConfigPath())
	case !store.Matches(config, relay):
		s.log.Print(ready)
		s.log.Printf("warning: %s does not carry this relay's key; run `ighostvt-relay rotate` to make a matching pair", dir.ConfigPath())
	case config.Endpoint != endpoint || config.Name != name:
		was := config.Endpoint
		config.Endpoint = endpoint
		config.Name = name
		if err := dir.SaveConfig(config); err != nil {
			return err
		}
		s.log.Print(ready)
		if was != endpoint {
			s.log.Printf("warning: the endpoint changed from %s to %s. The key is the same, but every device has to import the configuration again", was, endpoint)
		}
		s.log.Printf("ighostvt-relay: save the config with:\n    %s", SaveCommand)
	default:
		s.log.Print(ready)
		s.log.Printf("ighostvt-relay: save the config with:\n    %s", SaveCommand)
	}
	return nil
}

// Rotate makes a new key pair and configuration and drops every registered
// host; the old configuration stops working at once. Host bindings stay.
func (s *Server) Rotate() (string, error) {
	s.keyMu.Lock()
	defer s.keyMu.Unlock()
	s.mu.Lock()
	endpoint := s.endpoint
	s.mu.Unlock()
	if endpoint == "" {
		e, _, err := s.opts.Endpoint()
		if err != nil {
			return "", fmt.Errorf("the relay has no public address to write into the configuration (%v); set RELAY_PUBLIC_HOST", err)
		}
		endpoint = e
	}
	relayID := store.NewRelayID()
	if relay, err := s.opts.Dir.LoadRelay(); err == nil && relay != nil {
		relayID = relay.RelayID
	}
	r, c, err := store.NewKey(relayID, s.opts.Name, endpoint)
	if err != nil {
		return "", err
	}
	if err := s.opts.Dir.SaveConfig(c); err != nil {
		return "", err
	}
	if err := s.opts.Dir.SaveRelay(r); err != nil {
		return "", err
	}
	pub, _ := protocol.ParsePublicKey(r.PublicKey)
	s.mu.Lock()
	s.relayID = r.RelayID
	s.relayKey = pub
	s.keyGen++
	s.endpoint = endpoint
	hosts := make([]*hostConn, 0, len(s.hosts))
	for _, h := range s.hosts {
		hosts = append(hosts, h)
	}
	s.mu.Unlock()
	for _, h := range hosts {
		s.dropHost(h)
	}
	s.log.Printf("rotated the relay key; %d host(s) dropped", len(hosts))
	return fmt.Sprintf("New key written; %d host(s) dropped. Every device has to import the new configuration:\n    %s", len(hosts), SaveCommand), nil
}

// Forget removes a host id's binding, so the next registration binds a new
// key, and drops the host if it is online.
func (s *Server) Forget(hostID string) (string, error) {
	if !clienthello.IsUUID(hostID) {
		return "", errors.New("a host id is a UUID")
	}
	key := strings.ToLower(hostID)
	s.mu.Lock()
	_, bound := s.bindings[key]
	var err error
	if bound {
		delete(s.bindings, key)
		err = s.opts.Dir.SaveBindings(s.bindings)
	}
	h := s.hosts[key]
	s.mu.Unlock()
	if err != nil {
		return "", err
	}
	if h != nil {
		s.dropHost(h)
	}
	if !bound {
		return fmt.Sprintf("%s was not bound to a key", key), nil
	}
	s.log.Printf("host %s forgotten", key)
	return fmt.Sprintf("%s forgotten; its next registration binds a new host key", key), nil
}

// Status is what `ighostvt-relay status` prints.
type Status struct {
	RelayID        string              `json:"relayID"`
	Name           string              `json:"name"`
	Endpoint       string              `json:"endpoint"`
	Hosts          []protocol.HostInfo `json:"hosts"`
	BoundHosts     int                 `json:"boundHosts"`
	Splices        int                 `json:"splices"`
	PendingTickets int                 `json:"pendingTickets"`
}

// Status reports what the relay holds right now.
func (s *Server) Status() Status {
	hosts := s.onlineHosts()
	s.mu.Lock()
	defer s.mu.Unlock()
	return Status{
		RelayID:        s.relayID,
		Name:           s.opts.Name,
		Endpoint:       s.endpoint,
		Hosts:          hosts,
		BoundHosts:     len(s.bindings),
		Splices:        s.splices - len(s.tickets),
		PendingTickets: len(s.tickets),
	}
}
