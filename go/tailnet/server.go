// Package tailnet is the Go half of TailnetKit's server side: an embedded
// Tailscale node that serves an ordinary http.Handler on the tailnet.
//
// It is the counterpart of Sources/TailnetKit/Transport/TailnetServer.swift for
// hosts written in Go. The Swift version bridges tailnet connections to a
// loopback server because the app it serves is a separate process; a Go host
// already has the handler in hand, so this serves it directly and skips the
// byte pump. Either way the handler is unchanged — every route, auth check and
// rate limit the host already has applies to tailnet callers too.
package tailnet

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// Config describes the node. The identity persists in StateDirectory, so an
// auth key is consulted only on the first join.
type Config struct {
	// HostName is the node's name on the tailnet.
	HostName string
	// StateDirectory holds the node identity. It must survive restarts, or
	// every launch joins as a new device.
	StateDirectory string
	// AuthKey joins without an interactive sign-in. Empty means the host
	// must open the URL reported to OnLoginURL.
	AuthKey string
	// Ephemeral nodes are removed from the tailnet when they disconnect.
	Ephemeral bool
	// Logf receives tsnet's own logging. Nil discards it, which is usually
	// what a GUI app wants.
	Logf func(format string, args ...any)
}

// Hooks report progress. Every one is optional, and each may be called from a
// background goroutine.
type Hooks struct {
	// OnStatus receives display-ready progress text.
	OnStatus func(string)
	// OnLoginURL fires when the node needs interactive sign-in. Open it.
	OnLoginURL func(string)
	// OnAddress reports the node's tailnet IP once it is up — this is what
	// goes in the pairing QR.
	OnAddress func(string)
}

// Server is an embedded Tailscale node serving one handler.
type Server struct {
	cfg Config

	mu      sync.Mutex
	ts      *tsnet.Server
	address string
	ln      net.Listener
}

// NewServer prepares a node. Nothing starts until Serve is called.
func NewServer(cfg Config) *Server {
	return &Server{cfg: cfg}
}

// Address is the node's tailnet IP, empty until the node is up.
func (s *Server) Address() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.address
}

// Serve brings the node up and serves h on the tailnet at port. It blocks
// until ctx is cancelled or serving fails, and returns nil on a clean stop.
func (s *Server) Serve(ctx context.Context, port int, h http.Handler, hooks Hooks) error {
	status := func(text string) {
		if hooks.OnStatus != nil {
			hooks.OnStatus(text)
		}
	}

	logf := s.cfg.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	ts := &tsnet.Server{
		Hostname:  s.cfg.HostName,
		Dir:       s.cfg.StateDirectory,
		AuthKey:   s.cfg.AuthKey,
		Ephemeral: s.cfg.Ephemeral,
		Logf:      logf,
		UserLogf:  logf,
	}
	s.mu.Lock()
	s.ts = ts
	s.mu.Unlock()
	defer ts.Close()

	status("Starting Tailscale…")

	// Up blocks until the node is Running but never surfaces the sign-in URL,
	// so the bus is watched separately. Without this a host with no auth key
	// waits forever with nothing to show the user.
	watchCtx, stopWatch := context.WithCancel(ctx)
	defer stopWatch()
	go s.watchForLoginURL(watchCtx, ts, hooks, status)

	state, err := ts.Up(ctx)
	if err != nil {
		return fmt.Errorf("tailnet: bring node up: %w", err)
	}
	stopWatch()

	if len(state.TailscaleIPs) == 0 {
		return errors.New("tailnet: node is up but has no address")
	}
	address := state.TailscaleIPs[0].String()
	s.mu.Lock()
	s.address = address
	s.mu.Unlock()
	if hooks.OnAddress != nil {
		hooks.OnAddress(address)
	}
	status("Connected as " + address)

	ln, err := ts.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return fmt.Errorf("tailnet: listen on %d: %w", port, err)
	}
	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()

	// http.Serve has no context, so cancellation closes the listener under it,
	// which is what makes Serve return.
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	if err := http.Serve(ln, h); err != nil {
		// A closed listener is the expected end of a cancelled Serve.
		if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
			return nil
		}
		return fmt.Errorf("tailnet: serve: %w", err)
	}
	return nil
}

// watchForLoginURL reports the interactive sign-in URL if the node asks for
// one. It exits when the node is running or the context is cancelled.
func (s *Server) watchForLoginURL(ctx context.Context, ts *tsnet.Server, hooks Hooks, status func(string)) {
	lc, err := ts.LocalClient()
	if err != nil {
		return
	}
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		return
	}
	defer watcher.Close()

	for {
		n, err := watcher.Next()
		if err != nil {
			return // context cancelled, or the bus went away
		}
		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			status("Waiting for sign-in…")
			if hooks.OnLoginURL != nil {
				hooks.OnLoginURL(*n.BrowseToURL)
			}
		}
		if n.State != nil && *n.State == ipn.Running {
			return
		}
	}
}

// Close stops the node and its listener. Serve returns shortly after.
func (s *Server) Close() error {
	s.mu.Lock()
	ln, ts := s.ln, s.ts
	s.ln, s.ts = nil, nil
	s.mu.Unlock()

	if ln != nil {
		_ = ln.Close()
	}
	if ts != nil {
		return ts.Close()
	}
	return nil
}
