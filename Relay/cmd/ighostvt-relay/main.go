// Command ighostvt-relay is the iGhostVT relay: `serve` runs it, and the
// other subcommands are for `docker compose exec relay ighostvt-relay …`
// against the one that runs. See Relay/README.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/owngoal-dev/iGhostVT/Relay/internal/protocol"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/publicip"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/relay"
	"github.com/owngoal-dev/iGhostVT/Relay/internal/store"
)

// version is set at build time (-X main.version=…).
var version = "dev"

const usage = `usage: ighostvt-relay [command]

  serve            run the relay (the default)
  config           print the configuration devices import (.vtrpsc)
  rotate           make a new key; every device imports the new configuration
  forget <hostID>  unbind a host id from its host key (a reinstalled host)
  status           list the hosts online and the connections in use
  version          print the version

Environment: RELAY_PUBLIC_HOST, RELAY_PUBLIC_PORT, RELAY_NAME, RELAY_LISTEN,
RELAY_DATA. See the README.
`

func main() {
	command := "serve"
	args := os.Args[1:]
	if len(args) > 0 {
		command, args = args[0], args[1:]
	}
	dir := store.Dir(env("RELAY_DATA", "/data"))
	var err error
	switch command {
	case "serve":
		err = serve(dir)
	case "config":
		err = printConfig(dir)
	case "rotate":
		err = admin(dir, relay.AdminRequest{Command: "rotate"})
	case "forget":
		if len(args) != 1 {
			err = errors.New("usage: ighostvt-relay forget <hostID>")
			break
		}
		err = admin(dir, relay.AdminRequest{Command: "forget", HostID: args[0]})
	case "status":
		err = status(dir)
	case "version":
		fmt.Printf("ighostvt-relay %s (relay protocol %d)\n", version, protocol.Version)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "ighostvt-relay: %v\n", err)
		os.Exit(1)
	}
}

func env(name, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return fallback
}

func serve(dir store.Dir) error {
	logger := log.New(os.Stderr, "", 0)
	port, err := strconv.Atoi(env("RELAY_PUBLIC_PORT", "46405"))
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("RELAY_PUBLIC_PORT %q is not a port", os.Getenv("RELAY_PUBLIC_PORT"))
	}
	endpoint, err := endpointFunc(strings.TrimSpace(os.Getenv("RELAY_PUBLIC_HOST")), port, logger)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(string(dir), 0o700); err != nil {
		return err
	}
	limits := relay.DefaultLimits()
	if v := strings.TrimSpace(os.Getenv("RELAY_RATE_PER_IP")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return fmt.Errorf("RELAY_RATE_PER_IP %q is not a count (0 turns the limit off)", v)
		}
		limits.RatePerIP = n
	}
	server, err := relay.New(relay.Options{
		Dir:      dir,
		Name:     env("RELAY_NAME", "iGhostVT Relay"),
		Version:  version,
		Endpoint: endpoint,
		Limits:   limits,
		Logger:   logger,
	})
	if err != nil {
		return err
	}

	lc := net.ListenConfig{KeepAliveConfig: net.KeepAliveConfig{
		Enable: true, Idle: 10 * time.Second, Interval: 5 * time.Second, Count: 3,
	}}
	ln, err := lc.Listen(context.Background(), "tcp", env("RELAY_LISTEN", ":46405"))
	if err != nil {
		return err
	}
	adminLn, err := server.ListenAdmin(dir.AdminSocket())
	if err != nil {
		ln.Close()
		return err
	}
	go func() {
		if err := server.ServeAdmin(adminLn); err != nil {
			logger.Printf("admin socket: %v", err)
		}
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signals
		server.Close()
	}()
	err = server.Serve(ln)
	server.Close()
	os.Remove(dir.AdminSocket())
	return err
}

// endpointFunc says where the configuration points: RELAY_PUBLIC_HOST as it
// is, or — only when it is empty — the address Cloudflare and Google see.
func endpointFunc(host string, port int, logger *log.Logger) (relay.EndpointFunc, error) {
	if host != "" {
		bare := strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
		if strings.Contains(bare, ":") {
			if _, err := netip.ParseAddr(bare); err != nil {
				return nil, fmt.Errorf("RELAY_PUBLIC_HOST %q should be a domain or an IP without a port; the port is RELAY_PUBLIC_PORT", host)
			}
		}
		if strings.ContainsAny(bare, " /") {
			return nil, fmt.Errorf("RELAY_PUBLIC_HOST %q is not a domain or an IP", host)
		}
		endpoint := protocol.Endpoint(bare, port)
		return func() (string, string, error) { return endpoint, "from RELAY_PUBLIC_HOST", nil }, nil
	}
	return func() (string, string, error) {
		result, err := publicip.Detect(context.Background(), publicip.Default())
		if err != nil {
			return "", "", err
		}
		for _, w := range result.Warnings {
			logger.Printf("warning: %s", w)
		}
		return protocol.Endpoint(result.Addr.String(), port), "detected via " + result.Source, nil
	}, nil
}

func printConfig(dir store.Dir) error {
	data, err := dir.ConfigBytes()
	if errors.Is(err, fs.ErrNotExist) {
		if r, _ := dir.LoadRelay(); r != nil {
			return errors.New("the configuration was deleted, and the private key with it; `ighostvt-relay rotate` makes a new one (every device then imports it again)")
		}
		return errors.New("there is no configuration yet; check the relay's log (it needs RELAY_PUBLIC_HOST when the public address cannot be found)")
	}
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(data)
	return err
}

func admin(dir store.Dir, req relay.AdminRequest) error {
	resp, err := relay.Admin(dir.AdminSocket(), req)
	if err != nil {
		return err
	}
	if !resp.OK {
		return errors.New(resp.Message)
	}
	fmt.Println(resp.Message)
	return nil
}

func status(dir store.Dir) error {
	resp, err := relay.Admin(dir.AdminSocket(), relay.AdminRequest{Command: "status"})
	if err != nil {
		return err
	}
	if !resp.OK || resp.Status == nil {
		return errors.New(resp.Message)
	}
	st := resp.Status
	fmt.Printf("relay %q (%s)\n", st.Name, st.RelayID)
	if st.Endpoint != "" {
		fmt.Printf("endpoint   %s\n", st.Endpoint)
	} else {
		fmt.Println("endpoint   unknown (set RELAY_PUBLIC_HOST)")
	}
	fmt.Printf("splices    %d active, %d waiting for their host\n", st.Splices, st.PendingTickets)
	fmt.Printf("hosts      %d online, %d bound\n", len(st.Hosts), st.BoundHosts)
	if len(st.Hosts) > 0 {
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "\nID\tNAME\tVERSION\tSINCE")
		for _, h := range st.Hosts {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", h.ID, h.Name, h.AppVersion, time.Unix(h.Since, 0).UTC().Format(time.RFC3339))
		}
		w.Flush()
	}
	return nil
}
