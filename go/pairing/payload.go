// Package pairing is the Go half of TailnetKit's pairing contract: the QR
// payload a server mints and a client scans.
//
// It is a deliberate mirror of Sources/TailnetKit/Pairing/PairingPayload.swift.
// The wire format is the contract between them, so a Go server can pair a
// Swift client — which is the whole point, and a silent divergence would
// surface only as a scan that does nothing.
package pairing

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Version is bumped only for a breaking change to the transport fields.
// Adding app extras does not need a bump — that is what App is for.
const Version = 1

// Payload is everything a client needs to reach a server, in one scannable
// blob:
//
//	{"app":{…},"host":"100.x.y.z","port":8945,"token":"…","ts_key":"tskey-…","v":1}
//
// This package owns v/host/port/token/ts_key; anything the embedding app needs
// goes in App. Nesting app config under one key rather than spreading it across
// the top level keeps a client's decoder from colliding with a future
// transport field.
//
// Fields are declared in the order Swift's .sortedKeys encoder emits them, so
// both sides produce byte-identical JSON for the same payload. Decoding does
// not care about order; a stable encoding keeps the rendered QR stable across
// launches, which matters when the QR is on screen and someone is scanning it.
type Payload struct {
	// App is app-specific configuration, encoded as-is. Any JSON-marshalable
	// value; nil omits the key.
	App  any    `json:"app,omitempty"`
	Host string `json:"host"`
	Port int    `json:"port"`
	// Token is the bearer token for the server's API.
	Token string `json:"token"`
	// TailnetAuthKey lets the client join without its own interactive
	// sign-in. Empty means the client authenticates itself.
	TailnetAuthKey string `json:"ts_key,omitempty"`
	Version        int    `json:"v"`
}

// Option configures a Payload built by New.
type Option func(*Payload)

// WithAuthKey attaches a tailnet auth key so the client joins without an
// interactive sign-in. An empty key is ignored rather than encoded, so an
// unset key never rides along as an empty string a client would try to use.
//
// The normalisation happens here rather than being left to the field's
// omitempty tag, because that is where Swift does it: PairingPayload's
// initialiser maps "" to nil for the same reason. The encoding was
// already correct and already tested — this is about the two halves
// keeping the guarantee in the same place, so a caller reading
// Payload.TailnetAuthKey back sees absence on both sides rather than
// absence in the JSON and an empty string in the struct.
func WithAuthKey(key string) Option {
	return func(p *Payload) {
		if key != "" {
			p.TailnetAuthKey = key
		}
	}
}

// WithApp attaches app-specific configuration under "app".
func WithApp(app any) Option {
	return func(p *Payload) { p.App = app }
}

// New builds a payload at the current version.
func New(host string, port int, token string, opts ...Option) Payload {
	p := Payload{Version: Version, Host: host, Port: port, Token: token}
	for _, opt := range opts {
		opt(&p)
	}
	return p
}

// Encode renders the JSON that goes into the QR.
func (p Payload) Encode() (string, error) {
	if p.Version == 0 {
		p.Version = Version
	}
	if err := p.Validate(); err != nil {
		return "", err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	// Go escapes <, > and & by default. A token carrying one would then reach
	// the client as < and fail to authenticate, so escaping is off.
	enc.SetEscapeHTML(false)
	if err := enc.Encode(p); err != nil {
		return "", fmt.Errorf("encode pairing payload: %w", err)
	}
	// Encode appends a newline, which would change the QR's contents.
	return string(bytes.TrimRight(buf.Bytes(), "\n")), nil
}

// Decode parses a scanned string, rejecting anything that is not a usable
// payload — a wrong version, a blank host, a nonsense port. A camera hands
// over any QR in frame, including ones from other apps, so this is the gate.
func Decode(s string) (Payload, error) {
	var p Payload
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		return Payload{}, fmt.Errorf("not a pairing payload: %w", err)
	}
	if err := p.Validate(); err != nil {
		return Payload{}, err
	}
	return p, nil
}

// DecodeApp unmarshals the app extras of a decoded payload into v. Absent
// extras leave v untouched, matching the Swift side where `app` is optional.
func (p Payload) DecodeApp(v any) error {
	if p.App == nil {
		return nil
	}
	raw, err := json.Marshal(p.App)
	if err != nil {
		return fmt.Errorf("re-encode app extras: %w", err)
	}
	return json.Unmarshal(raw, v)
}

// Validate reports whether the payload is usable.
func (p Payload) Validate() error {
	switch {
	case p.Version != Version:
		return fmt.Errorf("pairing payload version %d, want %d", p.Version, Version)
	case p.Host == "":
		return fmt.Errorf("pairing payload has no host")
	case p.Port <= 0 || p.Port > 65535:
		return fmt.Errorf("pairing payload port %d out of range", p.Port)
	}
	return nil
}
