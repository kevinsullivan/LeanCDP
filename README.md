# LeanCDP

A pure-Lean 4 client for the Chrome DevTools Protocol (CDP), the
JSON-RPC-over-WebSocket protocol that Playwright and Puppeteer use to
drive a browser. Built on a generic WebSocket JSON-RPC client
(`LeanCDP.Rpc`) that CDP is one pluggable *dialect* of -- see
[Other dialects](#other-dialects).

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
| `LeanCDP.Rpc` | A generic WebSocket JSON-RPC client. A background reader per `Client` dispatches responses by request `id`, so multiple calls can be in flight at once, and queues id-less messages as events (`pollEvent`/`nextEvent`/the `*Matching` variants). Protocol-agnostic: a `Dialect` supplies request framing and response classification. |
| `LeanCDP.Dialects` | `cdp`, `jsonRpc2`, and `bidi` -- the `Rpc.Dialect`s this package ships. |
| `LeanCDP.Protocol` | The CDP-flavored client: `Rpc` plus `Dialects.cdp`, with CDP's session-scoped calls (`callSession`) and session-filtered events layered on top. |
| `LeanCDP.Discovery` | Reads `GET /json/version` and parses `webSocketDebuggerUrl`. |
| `LeanCDP.Page` | `Target.createTarget`/`attachToTarget`, `Page.navigate`/`captureScreenshot`, and `waitForLoad`, which waits on `Page.loadEventFired` scoped to its own session. |

Each layer depends only on the one below it: `Transport` knows
nothing about WebSockets; `WebSocket` knows nothing about RPC;
`Rpc` knows nothing about CDP or JSON-RPC 2.0 specifically -- a
`Dialect` is the only thing that does.

## Tests

`LeanCDP.Testing.Mocks` implements seven small WebSocket/HTTP servers,
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
  answered out of order both resolving to the correct caller;
- a JSON-RPC 2.0 peer, same shape but requiring the `"jsonrpc":"2.0"`
  field: `Rpc.connect Dialects.jsonRpc2` round-trips through a
  different dialect than CDP's;
- a WebDriver-BiDi-shaped peer, using `"type":"success"`/`"error"`/
  `"event"` instead of CDP's implicit shape: `Dialects.bidi` decodes
  both a successful call and an error one, the error with a readable
  message rather than an empty one.

Plus pure-function vectors for SHA-1 (FIPS 180-1), base64 (RFC 4648),
and the RFC 6455 §1.3 handshake example.

```sh
lake build
lake exe leancdp-test
```

25 checks, passing via `lake exe` and the built binary directly.

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

### Against a real Firefox

Firefox's `--remote-debugging-port` serves WebDriver BiDi, not CDP --
`Dialects.bidi` is what talks to it:

```sh
firefox-esr --headless --remote-debugging-port=9223 \
  --profile /tmp/leancdp-firefox-demo about:blank &
```

```lean
import LeanCDP

open LeanCDP Std.Async

def main : IO Unit := do
  let client ← (Rpc.connect Dialects.bidi "127.0.0.1" 9223 "/session").block
  let status ← (client.call "session.status").block
  IO.println status.compress  -- {"message":"","ready":true}
  (client.close).block
```

Confirmed against a real Firefox ESR, both a successful command
(`session.status`) and an error one (a CDP-shaped method BiDi
rejects, decoding to `"invalid session id: WebDriver session does
not exist, or is not active"` instead of an empty message).

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

## Other dialects

`LeanCDP.Protocol` is `LeanCDP.Rpc` plus `LeanCDP.Dialects.cdp`.
Anything else that puts JSON-RPC-shaped requests on a WebSocket --
`{"id","method","params"}`, responses keyed by that `id`, id-less
messages as events -- is reachable the same way, by supplying a
different `Rpc.Dialect`: a `buildRequest` and a `parse`, nothing more.
This package ships two others:

- `Dialects.jsonRpc2`, for strict JSON-RPC 2.0 servers:

  ```lean
  import LeanCDP

  open LeanCDP Std.Async

  def main : IO Unit := do
    let client ← (Rpc.connect Dialects.jsonRpc2 "127.0.0.1" 8080 "/").block
    let result ← (client.call "some.method" (Lean.Json.mkObj [])).block
    IO.println result.compress
    (client.close).block
  ```

- `Dialects.bidi`, for WebDriver BiDi (what Firefox's
  `--remote-debugging-port` serves) -- see
  [Against a real Firefox](#against-a-real-firefox).

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
  .callSession` directly but have no dedicated wrapper. The same is
  true of BiDi -- `Dialects.bidi` gets you a working `Rpc.Client`
  against Firefox, with no `Page`-equivalent convenience layer on top.
- No session/context-scoped BiDi commands. CDP's `callSession` tags a
  call with a `sessionId` field at the envelope level; BiDi instead
  expects a browsing-context id passed *inside* `params`, which
  `Rpc.Client.call` already supports (it's just another key in the
  `params` object) but nothing wraps for convenience.
