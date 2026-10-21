/-
`leancdp-test`: the test suite.

Pure vectors (FIPS 180-1 SHA-1, RFC 4648 base64, the RFC 6455 §1.3
worked handshake example, and `Discovery.parseWsUrl`) check the
non-networked pieces directly. Everything else spins up a small,
independently-written mock server from `LeanCDP.Testing.Mocks` and
drives the real `LeanCDP.Transport`/`WebSocket`/`Protocol`/`Discovery`
code against it over an actual loopback TCP connection:

- the WebSocket echo test covers the handshake, message fragmentation
  in both directions, the 126-length *and* 64-bit-length payload
  encodings in both directions, and unsolicited-`Ping` ->
  automatic-`Pong`;
- the invalid-UTF-8 test covers a Text frame getting rejected (close
  code 1007) rather than handed back as-is;
- the extension-rejection test covers `connect` refusing a server that
  selects `permessage-deflate` despite never having been offered it;
- the HTTP/JSON test covers `Discovery.version`/`fetchJson` against a
  real (if fake-content) HTTP response, and -- via a second connection
  to the same mock server -- `Transport.connect` resolving `"localhost"`
  through DNS rather than only accepting IPv4 literals;
- the CDP test covers `Protocol.Client.call`'s request-id round trip,
  an event arriving with no call in flight (`nextEvent`), and two
  calls answered out of send order both resolving to the *correct*
  caller;
- the JSON-RPC 2.0 test covers `Rpc.connect Dialects.jsonRpc2`'s
  round trip against a server speaking that dialect instead of CDP's;
- the BiDi test covers `Dialects.bidi`'s `type`-discriminated success
  and error envelopes, confirming an error decodes to a readable
  message rather than an empty one.

A live Chromium is covered separately by `ChromiumDemo.lean`. See
`README.md` for what's out of scope.
-/

import LeanCDP
import LeanCDP.Testing.Mocks

open LeanCDP LeanCDP.Codec LeanCDP.WebSocket Std.Async Lean

structure Check where
  name : String
  ok : Bool

def pureChecks : List Check := [
  ⟨"base64 encode: foobar", Base64.encode "foobar".toUTF8 == "Zm9vYmFy"⟩,
  ⟨"base64 encode: pad 1",  Base64.encode "fo".toUTF8 == "Zm8="⟩,
  ⟨"base64 encode: pad 2",  Base64.encode "f".toUTF8 == "Zg=="⟩,
  ⟨"base64 round-trip",     Base64.decode (Base64.encode "hello, CDP".toUTF8) == some "hello, CDP".toUTF8⟩,
  ⟨"base64 decode rejects garbage", Base64.decode "not valid!!" == none⟩,
  ⟨"sha1(\"\")",  SHA1.toHex (SHA1.digest "".toUTF8) == "da39a3ee5e6b4b0d3255bfef95601890afd80709"⟩,
  ⟨"sha1(\"abc\")", SHA1.toHex (SHA1.digest "abc".toUTF8) == "a9993e364706816aba3e25717850c26c9cd0d89d"⟩,
  ⟨"sha1 two-block vector",
    SHA1.toHex (SHA1.digest "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".toUTF8)
      == "84983e441c3bd26ebaae4aa1f95129e5e54670f1"⟩,
  ⟨"RFC 6455 §1.3 worked handshake example",
    WebSocket.expectedAccept "dGhlIHNhbXBsZSBub25jZQ==" == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="⟩,
  ⟨"Discovery.parseWsUrl",
    Discovery.parseWsUrl "ws://127.0.0.1:9222/devtools/browser/abc-123"
      == some ("127.0.0.1", (9222 : UInt16), "/devtools/browser/abc-123")⟩
]

/-- Client side of the WebSocket echo test, against `Mocks.runEchoServerOnce`. -/
def websocketEchoClient (port : UInt16) : Async (List Check) := do
  let conn ← WebSocket.connect "127.0.0.1" port "/leancdp-test"
  conn.sendText "hello"
  let short ← conn.recvMessage
  let longMsg := String.join (List.replicate 300 "x")
  conn.sendText longMsg
  let long ← conn.recvMessage
  -- 140,000 bytes: each half of the server's 2-fragment echo exceeds 65,535,
  -- so this is the only message in the suite that forces the 64-bit payload
  -- length (RFC 6455 §5.2, the `127` length-field case) on an actual send
  -- *and* receive, on both ends of the connection.
  let hugeMsg := String.join (List.replicate 140000 "z")
  conn.sendText hugeMsg
  let huge ← conn.recvMessage
  conn.close
  return [
    ⟨"handshake + short message fragmented across 2 frames and reassembled",
      short == some (.text, "hello".toUTF8)⟩,
    ⟨"long (300B, 126-length-encoded both ways) message fragmented and reassembled",
      long == some (.text, longMsg.toUTF8)⟩,
    ⟨"huge (140000B, 64-bit-length-encoded both ways) message fragmented and reassembled",
      huge == some (.text, hugeMsg.toUTF8)⟩
  ]

def websocketEchoChecks : IO (List Check) := do
  let port : UInt16 := 19222
  let srv ← (Testing.listenOn port).block
  let (sawPong, clientChecks) ←
    ((Testing.runEchoServerOnce srv).concurrently (websocketEchoClient port)).block
  return clientChecks ++ [⟨"server observed the client's auto-Pong reply", sawPong⟩]

/-- Connecting should fail outright -- not hang, not return a `Connection` that silently misreads frames. -/
def utf8Client (port : UInt16) : Async Check := do
  let ok ← try
      let conn ← WebSocket.connect "127.0.0.1" port "/leancdp-test"
      discard <| conn.recvMessage
      pure false  -- recvMessage should have thrown; reaching here is a failure
    catch _ => pure true
  return ⟨"invalid UTF-8 in a Text frame is rejected rather than handed back", ok⟩

def utf8Checks : IO (List Check) := do
  let port : UInt16 := 19226
  let srv ← (Testing.listenOn port).block
  let (sawClose1007, clientOk) ←
    ((Testing.runInvalidUtf8ServerOnce srv).concurrently (utf8Client port)).block
  return [clientOk, ⟨"client closed with status code 1007", sawClose1007⟩]

def extensionClient (port : UInt16) : Async Check := do
  let ok ← try
      discard <| WebSocket.connect "127.0.0.1" port "/leancdp-test"
      pure false  -- connect should have thrown; reaching here is a failure
    catch _ => pure true
  return ⟨"connect refuses a server that selects an unoffered extension", ok⟩

def extensionChecks : IO (List Check) := do
  let port : UInt16 := 19227
  let srv ← (Testing.listenOn port).block
  let (_, c) ← ((Testing.runExtensionServerOnce srv).concurrently (extensionClient port)).block
  return [c]

/-- Client side of the Discovery test, against `Mocks.runHttpJsonServerOnce`. -/
def discoveryClient (port wsPort : UInt16) : Async Check := do
  let (host, p, path) ← Discovery.discoverBrowserWebSocket "127.0.0.1" port
  return ⟨"Discovery.discoverBrowserWebSocket parses a /json/version response",
    host == "127.0.0.1" && p == wsPort && path == "/devtools/browser/mock-uuid"⟩

def discoveryChecks : IO (List Check) := do
  let port : UInt16 := 19223
  let wsPort : UInt16 := 19224
  let srv ← (Testing.listenOn port).block
  let (_, c) ← ((Testing.runHttpJsonServerOnce srv wsPort).concurrently (discoveryClient port wsPort)).block
  return [c]

/-- Same mock HTTP server as `discoveryChecks`, but connected to via the hostname
`"localhost"` instead of the literal `"127.0.0.1"`, to exercise `Transport.connect`'s
DNS fallback rather than its IPv4-literal fast path. -/
def dnsClient (port wsPort : UInt16) : Async Check := do
  let conn ← Transport.connect "localhost" port
  conn.send "GET /json/version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".toUTF8
  let body ← conn.recvAll
  let text := String.fromUTF8! body
  let found := (text.splitOn s!"ws://127.0.0.1:{wsPort}/devtools/browser/mock-uuid").length > 1
  return ⟨"Transport.connect resolves \"localhost\" via DNS", found⟩

def dnsChecks : IO (List Check) := do
  let port : UInt16 := 19228
  let wsPort : UInt16 := 19224
  let srv ← (Testing.listenOn port).block
  let (_, c) ← ((Testing.runHttpJsonServerOnce srv wsPort).concurrently (dnsClient port wsPort)).block
  return [c]

/-- Client side of the CDP protocol test, against `Mocks.runCdpMockServerOnce`. -/
def cdpClient (port : UInt16) : Async (List Check) := do
  let client ← Protocol.connect "127.0.0.1" port "/devtools/browser/mock-uuid"

  let ev ← client.nextEvent
  let eventCheck : Check :=
    ⟨"an event with no call in flight is queued and delivered by nextEvent",
      ev == ("Mock.ready", none, Json.mkObj [("ok", Json.bool true)])⟩

  let result ← client.call "Target.mockMethod" (Json.mkObj [("x", Json.num 1)])
  let expected := Json.mkObj [("echoedMethod", Json.str "Target.mockMethod"), ("params", Json.mkObj [("x", Json.num 1)])]
  let callCheck : Check :=
    ⟨"Protocol.Client.call round-trips a request id and decodes the JSON result",
      result == expected⟩

  -- "Slow" sleeps 300ms server-side before replying; "Fast" replies immediately.
  -- Firing both concurrently and awaiting them in the same (reversed) order they
  -- were sent proves the response that arrives *first* ("Fast"'s) resolves
  -- *its own* promise and not whichever `call` happened to be waiting first.
  let slowTask ← (client.call "Slow").asTask
  let fast ← client.call "Fast"
  let slow ← MonadAwait.await slowTask
  let concurrencyCheck : Check :=
    ⟨"two calls answered out of send order both resolve to the correct caller",
      fast == Json.mkObj [("echoedMethod", Json.str "Fast"), ("params", Json.mkObj [])] &&
      slow == Json.mkObj [("echoedMethod", Json.str "Slow"), ("params", Json.mkObj [])]⟩

  client.close
  return [eventCheck, callCheck, concurrencyCheck]

def cdpChecks : IO (List Check) := do
  let port : UInt16 := 19225
  let srv ← (Testing.listenOn port).block
  let (_, cs) ← ((Testing.runCdpMockServerOnce srv).concurrently (cdpClient port)).block
  return cs

/-- Client side of the JSON-RPC 2.0 test, against `Mocks.runJsonRpc2MockServerOnce`. -/
def jsonRpc2Client (port : UInt16) : Async Check := do
  let client ← Rpc.connect Dialects.jsonRpc2 "127.0.0.1" port "/jsonrpc2-test"
  let result ← client.call "ping" (Json.mkObj [("x", Json.num 1)])
  client.close
  let expected := Json.mkObj [("echoedMethod", Json.str "ping"), ("params", Json.mkObj [("x", Json.num 1)])]
  return ⟨"Rpc.Client.call round-trips over the JSON-RPC 2.0 dialect", result == expected⟩

def jsonRpc2Checks : IO (List Check) := do
  let port : UInt16 := 19229
  let srv ← (Testing.listenOn port).block
  let (_, c) ← ((Testing.runJsonRpc2MockServerOnce srv).concurrently (jsonRpc2Client port)).block
  return [c]

/-- Client side of the BiDi test, against `Mocks.runBidiMockServerOnce`. -/
def bidiClient (port : UInt16) : Async (List Check) := do
  let client ← Rpc.connect Dialects.bidi "127.0.0.1" port "/session"
  let result ← client.call "session.status"
  let expected := Json.mkObj [("echoedMethod", Json.str "session.status"), ("params", Json.mkObj [])]
  let successCheck : Check :=
    ⟨"Rpc.Client.call round-trips over the BiDi dialect's type:success envelope", result == expected⟩

  let errText ← try
      discard <| client.call "boom"
      pure ""
    catch e => pure (toString e)
  let errorCheck : Check :=
    ⟨"BiDi's type:error envelope decodes to a readable message, not an empty one",
      (errText.splitOn "boom error").length > 1 && (errText.splitOn "boom detail").length > 1⟩

  client.close
  return [successCheck, errorCheck]

def bidiChecks : IO (List Check) := do
  let port : UInt16 := 19230
  let srv ← (Testing.listenOn port).block
  let (_, cs) ← ((Testing.runBidiMockServerOnce srv).concurrently (bidiClient port)).block
  return cs

-- `main` exits via `IO.Process.exit` rather than `return`: the live checks leave
-- libuv TCP sockets and its background event-loop thread behind even once
-- every `Async` action involved has produced its result, which otherwise
-- leaves the process hanging after printing everything it has to say.
def main : IO Unit := do
  let live :=
    (← websocketEchoChecks) ++ (← utf8Checks) ++ (← extensionChecks) ++
    (← discoveryChecks) ++ (← dnsChecks) ++ (← cdpChecks) ++ (← jsonRpc2Checks) ++ (← bidiChecks)
  let all := pureChecks ++ live
  for c in all do
    let status := if c.ok then "ok  " else "FAIL"
    IO.println s!"{status} -- {c.name}"
  let failures := all.filter (fun c => !c.ok)
  if failures.isEmpty then
    IO.println s!"{all.length}/{all.length} checks passed"
    IO.Process.exit 0
  else
    IO.println s!"{failures.length}/{all.length} checks FAILED"
    IO.Process.exit 1
