# TailnetKit

Client/server pairing over an embedded Tailscale node, configured by scanning
one QR code.

Both ends of your app run their own userspace Tailscale node (tsnet, via
[libtailscale](https://github.com/tailscale/libtailscale)) — no system
Tailscale app, no VPN profile, no packet-tunnel extension. The server keeps its
loopback-only bind and TailnetKit bridges tailnet connections to it, so every
route, auth check and rate limit you already have applies unchanged.

The QR carries the address, the API token, an optional tailnet auth key, and
whatever else your app needs. One scan and the client is configured, joined and
connected.

## Setup

`TailscaleKit.xcframework` is a build artifact — around 100MB across its three
slices — so it is not checked in:

```bash
make bootstrap
```

That builds the Go archives and the macOS, iOS and iOS-Simulator slices, then
combines them into `binary/TailscaleKit.xcframework`. Re-run it whenever
`Vendor/libtailscale` changes. It needs Xcode (not just Command Line Tools) and
Go; override `DEVELOPER_DIR` if Xcode is not at the default path.

Then depend on the package by path or URL, and add the products you need —
`TailnetKit` for the transport, `TailnetKitUI` for the ready-made screens.

`make bootstrap` is a prerequisite for *consuming* the package too, not just for
working on it: resolution succeeds without the xcframework and the build then
fails with `local binary target 'TailscaleKit' ... does not contain a binary
artifact`, naming a path inside `.build/checkouts` rather than the command that
fills it.

Consider keeping the parts that do not touch the transport in a target that does
not depend on TailnetKit — a model and an API client need a base URL, a token
and a `URLSession`, none of which require a tunnel. That layer then builds and
tests in a second on any machine, and only the app target needs the artifact.

## Server side

```swift
let server = TailnetServer(
    hostName: "acme",
    stateDirectory: appSupport.appending(component: "tsnet"),
    logFile: appSupport.appending(component: "tsnet/tsnet.log"))

await server.start(
    authKey: authKey,           // empty runs browser sign-in instead
    port: 8945,
    onStatus: { status in ... },        // status.label is display-ready
    onLoginURL: { NSWorkspace.shared.open($0) },
    onAddress: { tailnetIP = $0 })      // feeds the pairing QR
```

Mint the QR from the address it reports:

```swift
struct AcmeConfig: Codable, Sendable { var theme: String }

let payload = PairingPayload(
    host: tailnetIP, port: 8945, token: apiToken,
    tailnetAuthKey: authKey,             // omit to make the client sign in
    app: AcmeConfig(theme: "dark"))

PairingQRView(payload: payload, instruction: "Acme → Settings → Scan Pairing QR")
```

## Client side

```swift
let connection = TailnetConnection(
    configuration: .init(
        hostName: "acme-ios",
        stateDirectory: TailnetConnection.Configuration.defaultStateDirectory(),
        keychainService: "com.example.acme",
        environmentPrefix: "ACME",       // ACME_HOST etc. override, for automation
        defaultPort: 8945))

// Make "connected" mean the server actually answered.
connection.verify = { baseURL in
    _ = try await AcmeAPI.health(baseURL)
    return "Connected"
}
```

Gate your UI on `connection.isConfigured`, and show the pairing screen when it
is false:

```swift
PairingWelcomeView<AcmeConfig>(
    connection: connection,
    message: "On your Mac, open Acme → Settings → Pair device, then scan.",
    onPaired: { config in applyTheme(config?.theme) })
```

Then issue requests against `connection.baseURL` with `connection.urlSession`,
sending `connection.apiToken` as a bearer token. In tailnet mode `baseURL`
points at a local relay, not the server's tailnet address — see below.

## Go hosts

The server half has a Go counterpart under `go/`, for hosts that are not Swift
apps. It speaks the same pairing format, so a Go server pairs a Swift client
with no translation layer in between.

The module is private and its packages pull in `tailscale.com`, so a fresh
consumer needs three lines before the first build — and naming the packages
rather than the module, since `go get` on the module alone reports success and
leaves `tailscale.com/tsnet` out of `go.sum`:

```bash
go env -w GOPRIVATE='github.com/mdcfrancis/*'
git config --global credential.https://github.com.helper '!gh auth git-credential'
go get github.com/mdcfrancis/tailnetkit/go/tailnet github.com/mdcfrancis/tailnetkit/go/pairing
```

Worth knowing what that costs before you start: `tailscale.com` and
`gvisor.dev/gvisor` are a large tree, and a host with a dependency policy may
need to clear it explicitly.

```go
node := tailnet.NewServer(tailnet.Config{
    HostName:       "acme",
    StateDirectory: filepath.Join(appDir, "tsnet"),
    AuthKey:        authKey, // empty runs browser sign-in instead
})

go node.Serve(ctx, 8945, handler, tailnet.Hooks{
    OnStatus:   func(text string) { log.Println(text) },
    OnLoginURL: func(url string) { exec.Command("open", url).Start() },
    OnAddress:  func(ip string) { tailnetIP = ip }, // feeds the pairing QR
})
```

Unlike the Swift `TailnetServer`, which pumps tailnet connections to a separate
loopback process, a Go host already holds the `http.Handler` — so it is served
directly and there is no byte pump. Either way the handler is unchanged.

Mint the QR from the address it reports:

```go
payload := pairing.New(tailnetIP, 8945, apiToken,
    pairing.WithAuthKey(authKey),          // omit to make the client sign in
    pairing.WithApp(AcmeConfig{Theme: "dark"}))

png, err := pairing.QRPNG(payload, 512)
```

`pairing` mirrors `PairingPayload` field for field and encodes byte-identically
to Swift's `.sortedKeys` output, which its tests assert — a divergence there
would otherwise surface only as a scan that does nothing.

The module lives in `go/` rather than at the repo root because
`Vendor/libtailscale` is seen as Go's `vendor/` on a case-insensitive
filesystem, which breaks every build at the root.

## What's inside

| | |
|---|---|
| `TailnetNode` | node lifecycle plus the browser sign-in (IPN bus) dance |
| `TailnetServer` | accepts on the tailnet, pumps to your loopback server |
| `TailnetRelay` | accepts on loopback, pumps over a tsnet dial |
| `TailnetConnection` | client settings, secrets, transport, `baseURL` |
| `PairingPayload<Extra>` | versioned QR payload, generic over your config |
| `PairingQR` | payload → `CGImage` |
| `KeychainStore` / `SecretFile` / `BearerToken` | secret storage |
| `ConsoleLogger` / `FileLogger` / `SilentLogger` | `LogSink`s you can construct |

`TailnetKitUI` adds `PairingQRView` (macOS), `PairScannerView` and
`PairingScannerSheet` (iOS), and `PairingWelcomeView` (iOS).

On the Go side, `go/tailnet` is `TailnetNode` + `TailnetServer` and
`go/pairing` is `PairingPayload` + `PairingQR`. There is no Go client: a Go
process reaching a tailnet service wants plain `tsnet.Dial`, not a loopback
relay, which exists only because `URLSession` cannot use a SOCKS proxy for
cleartext HTTP on iOS.

## Things worth knowing

- **The client talks to a loopback relay, not a proxy.** `URLSession`'s SOCKS
  `proxyConfigurations` silently drops cleartext HTTP on iOS, so `TailnetRelay`
  binds 127.0.0.1 and pumps each connection over a native tsnet dial instead.
  This is why `baseURL` is a localhost URL in tailnet mode.

- **"The handler is unchanged" is a promise about routing, not about auth.**
  Every check you already have does apply — which is the problem when those
  checks are about *where* a request came from rather than *what* it carries. A
  server that requires a loopback `Host`, or browser fetch metadata for CSRF,
  will refuse every paired device: a tailnet client sends `100.x.y.z` as `Host`
  and no fetch metadata at all. Loosening either check to let the tailnet in
  gives up the defence on the loopback listener, where it was doing real work.
  Give the tailnet listener its own chain instead — the routes are shared, the
  gates are not:

  ```go
  srv := &http.Server{Handler: localOnly(mux)}       // a browser: Host + fetch metadata
  node.Serve(ctx, port, bearerAuth(token, apiMux), hooks)  // a native client: the token
  ```

- **Auth keys are only needed once.** The node identity persists in
  `stateDirectory`; after the first join the key is never consulted. Reusable
  auth keys expire within 90 days (affecting new pairings only) and node keys
  within 180 — disable key expiry per-device in the admin console for anything
  long-lived.

- **`PairingPayload` extras are forward and backward compatible.** Unknown keys
  are ignored and `app` is optional, so a server that starts sending extras
  still pairs an older client. Bump `v` only for a breaking change to the
  transport fields.

- **Persistence keys are load-bearing.** `Mode.tailscale` has the raw value
  `"tailscale"`, and `defaultsPrefix` defaults to empty. Changing either on a
  shipped app reads to users as being silently logged out.

- **Set `GODEBUG=netdns=cgo` in your Info.plist `LSEnvironment`.** TailnetKit
  calls `setenv` too, but Go snapshots the environment at process load, so the
  plist is the one that reliably takes. Without it, DNS-proxy setups such as
  Cloudflare WARP return AAAA-only answers and every control-plane dial goes to
  IPv6 on networks with no v6 route — the sign-in URL can never be fetched.

- **Cloudflare WARP filters per-process** and will refuse dials from unsigned
  or ad-hoc-signed dev binaries. A first join may need WARP paused; the durable
  fix is split-tunnel exclusions for `*.tailscale.com` and `100.64.0.0/10`.

- **iOS needs camera and network usage strings**:
  `NSCameraUsageDescription` for the scanner, and
  `NSAppTransportSecurity.NSAllowsArbitraryLoads` since the tunnel carries
  cleartext HTTP (WireGuard is doing the encrypting).

## Vendored dependency

`Vendor/libtailscale` is a copy of tailscale/libtailscale (BSD-3-Clause) with
local additions, each marked in-place:

- `IncomingConnection.detachFD()` / `OutgoingConnection.detachFD()` — transfer
  fd ownership to the caller, which is what makes the byte pumps possible
- `netns.SetEnabled(false)` in `tailscale.go` — tsnet's bind-to-interface is
  pointless against a userspace netstack and actively breaks under WARP

Re-apply both if the vendor copy is ever updated.

## Licence

TailnetKit is MIT. `Vendor/libtailscale` is BSD-3-Clause; see its own LICENSE.
