# LeanCDP

A pure-Lean 4 client for the Chrome DevTools Protocol (CDP), the
JSON-RPC-over-WebSocket protocol that Playwright and Puppeteer use to
drive a browser.

A plain Lake package with no `require`s. No Mathlib, no FFI, no
dependency beyond the Lean 4 toolchain itself.

## Getting started

Open this folder in VS Code with the Dev Containers extension (or any
other devcontainer-compatible tool). The container provides `elan`,
`lake`, a headless-capable Chromium, and the Lean 4 VS Code extension.
The Lean toolchain itself is fetched on the first `lake build`, per
`lean-toolchain`.

```sh
lake build
lake exe leancdp-test
```

See `.devcontainer/` for the image definition.

## Why pure Lean, no FFI

Lean 4's `Std` library ships async networking (`Std.Async.TCP`, over
libuv via `Std.Internal.UV`) and JSON (`Lean.Data.Json`) as part of
the toolchain. Both are reachable from a plain `lean_lib`, with no
`require` line. `LeanCDP` talks to a browser's debugging port
directly — no Node, Python, or existing Playwright/Puppeteer
installation involved. The two pieces `Std` doesn't ship — SHA-1 and
base64, both needed for the WebSocket handshake — are implemented in
`LeanCDP.Codec`.

## Layers

| Module | What it does |
|---|---|
| `LeanCDP.Transport` | Async TCP: `connect` (IPv4 literal or hostname, via `Std.Async.DNS`), `send`/`recv?`/`close`, and `Buffered` — read exactly N bytes, or until a delimiter — shared by `WebSocket` and `Discovery`. |
| `LeanCDP.Codec.Base64` | RFC 4648 base64 encode/decode. |
| `LeanCDP.Codec.SHA1` | FIPS 180-1 SHA-1. |
| `LeanCDP.WebSocket` | RFC 6455 client: handshake, client-side masking, all three payload-length encodings, fragment reassembly, `Ping`/`Pong`, UTF-8 validation of Text messages. |
| `LeanCDP.Protocol` | The CDP JSON-RPC envelope. A background reader per `Client` dispatches responses by request `id`, so multiple calls can be in flight at once, and queues id-less messages as events (`pollEvent`/`nextEvent`/the session-filtered `*Matching` variants). |
| `LeanCDP.Discovery` | Reads `GET /json/version` and parses `webSocketDebuggerUrl`. |
| `LeanCDP.Page` | `Target.createTarget`/`attachToTarget`, `Page.navigate`/`captureScreenshot`, and `waitForLoad`, which waits on `Page.loadEventFired` scoped to its own session. |

Each layer depends only on the one below it: `Transport` knows
nothing about WebSockets; `WebSocket` knows nothing about CDP or
JSON; `Protocol` knows nothing about how the WebSocket URL was found.

## Tests

`LeanCDP.Testing.Mocks` implements five small WebSocket/HTTP servers,
independent of the client's own code, and `Tests.lean` drives the
real client against each over loopback TCP:

- a WebSocket echo server: handshake, fragmentation, the 126-length
  and 64-bit-length payload encodings, `Ping`→`Pong`;
- a server that sends an invalid-UTF-8 Text frame: `WebSocket` closes
  with code 1007 instead of returning the bytes;
- a server whose handshake response selects `permessage-deflate`
  without being offered it: `connect` refuses the handshake;
- an HTTP server returning a `/json/version`-shaped body, reached both
  by literal and by `"localhost"`: `Discovery` and DNS resolution;
- a CDP peer that echoes `{"id","method","params"}` as
  `{"id","result"}`, with an artificial delay on one method: request
  correlation, event delivery with no call in flight, and two calls
  answered out of order both resolving to the correct caller.

Plus pure-function vectors for SHA-1 (FIPS 180-1), base64 (RFC 4648),
and the RFC 6455 §1.3 handshake example.

```sh
lake build
lake exe leancdp-test
```

22 checks, passing via `lake exe` and the built binary directly.

### Against a real Chromium

`lake exe leancdp-chromium-demo` (`ChromiumDemo.lean`) runs
`Discovery` → `Protocol.connect` → `Client.call` → `LeanCDP.Page`
against a headless Chromium:

```sh
chromium --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \
  --user-data-dir=/tmp/leancdp-chromium-demo about:blank &
lake exe leancdp-chromium-demo
```

It calls `Browser.getVersion` and `Target.getTargets`, opens a tab,
runs JavaScript in it via `Runtime.evaluate`, and screenshots it,
writing `chromium-demo-screenshot.png`.

## Using it

```sh
lake exe leancdp-screenshot <url> [outfile] [cdp-host] [cdp-port]
# e.g.
lake exe leancdp-screenshot http://127.0.0.1:8111/index.html shot.png
```

`leancdp-screenshot` (`Screenshot.lean`) needs a Chromium already
listening, as above. It wraps `LeanCDP.Page`:
`Discovery.discoverBrowserWebSocket`, `Protocol.connect`,
`Page.openBlank`, `.navigate`, `.waitForLoad`, `.screenshot`, write
the bytes, `.close`. `ChromiumDemo.lean` uses the same API more fully;
`LeanCDP/Page.lean` documents each step.

Everything in `LeanCDP` runs in the `Async` monad. An `IO`-returning
`main` reaches it via `.block` (`someAsyncAction.block : IO α`).

`leancdp-probe` (`Main.lean`) is a smaller smoke test of the
`Transport` layer alone — a raw HTTP GET:

```sh
lake exe leancdp-probe <ipv4-host> <port> [path]
```

## Design notes

- **No `permessage-deflate` or other WebSocket extensions.** The
  handshake request never lists an extension in
  `Sec-WebSocket-Extensions`; RFC 6455 §9.1 forbids a compliant server
  from selecting one the client didn't offer. `connect` also refuses
  the handshake if a server's response names an extension anyway,
  rather than misread compressed frames as raw bytes.
- **`Transport.Connection.close` is best-effort.** Closing an
  already-closed connection succeeds rather than raising — a peer
  tearing down the connection before `close` runs is not an error
  condition.

## Known gaps

- No typed per-CDP-domain API. `Protocol.Client.call`/`callSession`
  are generic (`call "Page.navigate" params` works for any CDP
  method); typed request/response wrappers for the full protocol are
  a separate project.
- `LeanCDP.Page` covers one workflow: open a tab, navigate, wait for
  load, screenshot, run JavaScript, close. Other domains (`DOM`,
  `Network`, `Input`, ...) are reachable via `Protocol.Client
  .callSession` directly but have no dedicated wrapper.
- No CDP target other than Chromium. Firefox's `--remote-debugging-port`
  serves WebDriver BiDi, not CDP -- `WebSocket` interoperates with it
  (the RFC 6455 handshake and framing are protocol-agnostic), and a
  well-formed BiDi command round-trips through `Protocol.Client.call`
  since both protocols' success envelopes are `{"id","result"}`, but
  BiDi's error envelope (`{"error":"<string>","message":"<string>"}`)
  doesn't match `Message.parse`'s CDP-shaped `{"error":{"code",
  "message"}}`, so errors from a non-CDP peer decode as empty.
