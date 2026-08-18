package pairing

import (
	"strings"
	"testing"
)

// The wire format is the contract with the Swift client, so these mirror
// Tests/TailnetKitTests/PairingPayloadTests.swift. A change that breaks a
// scan should fail here rather than on someone's phone.

func TestEncodeMatchesSwiftSortedKeyOutput(t *testing.T) {
	p := New("100.64.1.2", 8945, "abc123", WithAuthKey("tskey-auth-xyz"))
	got, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	// Byte-for-byte what Swift's .sortedKeys encoder produces.
	want := `{"host":"100.64.1.2","port":8945,"token":"abc123","ts_key":"tskey-auth-xyz","v":1}`
	if got != want {
		t.Fatalf("encoded:\n got %s\nwant %s", got, want)
	}
}

func TestEncodeWithAppExtrasSortsAppFirst(t *testing.T) {
	type demo struct {
		Theme string `json:"theme"`
	}
	p := New("h", 80, "t", WithApp(demo{Theme: "dark"}))
	got, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	want := `{"app":{"theme":"dark"},"host":"h","port":80,"token":"t","v":1}`
	if got != want {
		t.Fatalf("encoded:\n got %s\nwant %s", got, want)
	}
}

func TestRoundTrip(t *testing.T) {
	p := New("100.64.1.2", 8945, "abc123", WithAuthKey("tskey-auth-xyz"))
	encoded, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	back, err := Decode(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if back.Host != "100.64.1.2" || back.Port != 8945 ||
		back.Token != "abc123" || back.TailnetAuthKey != "tskey-auth-xyz" {
		t.Fatalf("round trip lost fields: %+v", back)
	}
}

// A QR minted before app extras existed must keep working.
func TestDecodesPayloadWithoutExtras(t *testing.T) {
	const legacy = `{"host":"100.64.1.2","port":8945,"token":"abc","ts_key":"tskey-1","v":1}`
	p, err := Decode(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if p.App != nil {
		t.Fatalf("app = %v, want nil", p.App)
	}
	if p.TailnetAuthKey != "tskey-1" {
		t.Fatalf("ts_key = %q", p.TailnetAuthKey)
	}
}

// A newer server may send extras this build knows nothing about.
func TestIgnoresUnknownExtras(t *testing.T) {
	const future = `{"app":{"somethingNew":42},"host":"h","port":80,"token":"t","v":1}`
	if _, err := Decode(future); err != nil {
		t.Fatalf("future payload rejected: %v", err)
	}
}

func TestDecodeAppExtras(t *testing.T) {
	type demo struct {
		Theme string `json:"theme"`
	}
	p, err := Decode(`{"app":{"theme":"dark"},"host":"h","port":80,"token":"t","v":1}`)
	if err != nil {
		t.Fatal(err)
	}
	var extras demo
	if err := p.DecodeApp(&extras); err != nil {
		t.Fatal(err)
	}
	if extras.Theme != "dark" {
		t.Fatalf("theme = %q", extras.Theme)
	}

	// Absent extras leave the target untouched rather than erroring.
	plain, err := Decode(`{"host":"h","port":80,"token":"t","v":1}`)
	if err != nil {
		t.Fatal(err)
	}
	extras = demo{Theme: "unchanged"}
	if err := plain.DecodeApp(&extras); err != nil {
		t.Fatal(err)
	}
	if extras.Theme != "unchanged" {
		t.Fatalf("absent extras overwrote the target: %q", extras.Theme)
	}
}

func TestRejectsUnusablePayloads(t *testing.T) {
	for name, raw := range map[string]string{
		"wrong version":   `{"host":"h","port":80,"token":"t","v":2}`,
		"missing version": `{"host":"h","port":80,"token":"t"}`,
		"blank host":      `{"host":"","port":80,"token":"t","v":1}`,
		"zero port":       `{"host":"h","port":0,"token":"t","v":1}`,
		"huge port":       `{"host":"h","port":70000,"token":"t","v":1}`,
		"not json":        `hello`,
		"other app's QR":  `https://example.com`,
	} {
		if _, err := Decode(raw); err == nil {
			t.Errorf("%s: accepted %q", name, raw)
		}
	}
}

// An empty auth key must be absent, not an empty string a client would try to
// join with.
func TestEmptyAuthKeyIsOmitted(t *testing.T) {
	encoded, err := New("h", 80, "t", WithAuthKey("")).Encode()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(encoded, "ts_key") {
		t.Fatalf("empty auth key encoded: %s", encoded)
	}
}

// Tokens are opaque; one containing HTML punctuation must survive intact.
func TestTokenIsNotHTMLEscaped(t *testing.T) {
	encoded, err := New("h", 80, "a<b&c>d").Encode()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(encoded, "a<b&c>d") {
		t.Fatalf("token was escaped: %s", encoded)
	}
	back, err := Decode(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if back.Token != "a<b&c>d" {
		t.Fatalf("token = %q", back.Token)
	}
}

func TestQRPNGIsDecodablePNG(t *testing.T) {
	png, err := QRPNG(New("100.64.1.2", 8945, "abc123"), 256)
	if err != nil {
		t.Fatal(err)
	}
	// PNG magic: a truncated or empty render would still be a []byte, so the
	// header is what actually says an image came back.
	if len(png) < 8 || string(png[1:4]) != "PNG" {
		t.Fatalf("not a PNG: %d bytes", len(png))
	}
}

func TestQRPNGRejectsUnusablePayload(t *testing.T) {
	if _, err := QRPNG(Payload{Version: Version, Port: 80}, 256); err == nil {
		t.Fatal("rendered a QR for a payload with no host")
	}
}

// The encoding is already covered by TestEmptyAuthKeyIsOmitted above.
// What this adds is the field: Swift's initialiser maps "" to nil, so a
// caller reading the payload back sees absence on both sides rather than
// absence in the JSON and an empty string in the struct.
func TestEmptyAuthKeyLeavesTheFieldUnset(t *testing.T) {
	if p := New("h", 80, "t", WithAuthKey("")); p.TailnetAuthKey != "" {
		t.Errorf("TailnetAuthKey = %q, want it unset", p.TailnetAuthKey)
	}
	// A real key is untouched, so the normalisation cannot be mistaken
	// for dropping the feature.
	if p := New("h", 80, "t", WithAuthKey("tskey-auth-xyz")); p.TailnetAuthKey != "tskey-auth-xyz" {
		t.Errorf("TailnetAuthKey = %q", p.TailnetAuthKey)
	}
}
