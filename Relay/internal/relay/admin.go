package relay

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"time"
)

// AdminRequest is one line on the admin socket.
type AdminRequest struct {
	Command string `json:"command"` // rotate, forget, status
	HostID  string `json:"hostID,omitempty"`
}

// AdminResponse is the answer, one line back.
type AdminResponse struct {
	OK      bool    `json:"ok"`
	Message string  `json:"message,omitempty"`
	Status  *Status `json:"status,omitempty"`
}

// ListenAdmin opens the admin socket, replacing one a previous run left. The
// socket is the relay user's alone; `docker compose exec` runs as that user.
func (s *Server) ListenAdmin(path string) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// ServeAdmin answers admin requests until the listener closes.
func (s *Server) ServeAdmin(ln net.Listener) error {
	if !s.track(ln) {
		return net.ErrClosed
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.handleAdmin(conn)
	}
}

func (s *Server) handleAdmin(conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	var req AdminRequest
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		return
	}
	var resp AdminResponse
	var err error
	switch req.Command {
	case "status":
		st := s.Status()
		resp.Status = &st
	case "rotate":
		resp.Message, err = s.Rotate()
	case "forget":
		resp.Message, err = s.Forget(req.HostID)
	default:
		err = fmt.Errorf("unknown command %q", req.Command)
	}
	resp.OK = err == nil
	if err != nil {
		resp.Message = err.Error()
	}
	json.NewEncoder(conn).Encode(resp)
}

// Admin sends one request to a running relay.
func Admin(path string, req AdminRequest) (AdminResponse, error) {
	var resp AdminResponse
	conn, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return resp, fmt.Errorf("the relay is not running (%w)", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return resp, err
	}
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return resp, err
	}
	return resp, nil
}
