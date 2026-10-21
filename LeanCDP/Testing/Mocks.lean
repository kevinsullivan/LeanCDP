/-
Test-only support: small servers standing in for the other end of the
wire in `Tests.lean`. Not part of the public `LeanCDP` library.

The WebSocket framing here is independent of `LeanCDP.WebSocket`'s
client-side code: testing the client against this cross-checks two
separate implementations of the same wire format.
-/

import LeanCDP.Transport
import LeanCDP.WebSocket
import Lean.Data.Json
import Std.Async.Timer

namespace LeanCDP.Testing

open Std.Net Std.Async LeanCDP.Codec Lean

private structure Peer where
  client : TCP.Socket.Client
  buf : IO.Ref ByteArray

private def Peer.fill (p : Peer) : Async Bool := do
  match ← p.client.recv? 65536 with
  | some chunk => p.buf.modify (· ++ chunk); return true
  | none => return false

private partial def Peer.ensure (p : Peer) (n : Nat) : Async Bool := do
  let rec loop : Async Bool := do
    if (← p.buf.get).size ≥ n then return true
    else if ← p.fill then loop else return false
  loop

private def Peer.take (p : Peer) (n : Nat) : Async ByteArray := do
  let b ← p.buf.get
  p.buf.set (b.extract n b.size)
  return b.extract 0 n

private def findSub (hay : ByteArray) (needle : ByteArray) : Option Nat := Id.run do
  let n := hay.size
  let m := needle.size
  let mut result : Option Nat := none
  if m == 0 then return none
  if m ≤ n then
    for start in [0 : n - m + 1] do
      if result.isNone then
        let mut matched := true
        for j in [0:m] do
          if hay.get! (start + j) != needle.get! j then matched := false
        if matched then result := some start
  return result

private partial def Peer.readUntil (p : Peer) (delim : ByteArray) : Async ByteArray := do
  let rec loop : Async ByteArray := do
    let cur ← p.buf.get
    match findSub cur delim with
    | some idx =>
      p.buf.set (cur.extract (idx + delim.size) cur.size)
      return cur.extract 0 idx
    | none =>
      if ← p.fill then loop
      else throw <| .userError "Mocks: peer closed before delimiter"
  loop

/--
Bind and listen on `127.0.0.1:port` before any client can connect. A
separate, eagerly-run step rather than folded into each `run*Once`:
`Async`'s `concurrently` guarantees both sides eventually run, not
that `listen` happens before a racing client's `connect` -- a client
connecting before anything is listening hangs rather than failing
fast.
-/
def listenOn (port : UInt16) : Async TCP.Socket.Server := do
  let srv ← TCP.Socket.Server.mk
  let some ipv4 := IPv4Addr.ofString "127.0.0.1" | throw <| .userError "bad literal"
  srv.bind (.v4 { addr := ipv4, port := port })
  srv.listen 16
  return srv

/-- Decode exactly one client → server WebSocket frame. Client frames are always masked. -/
private def Peer.recvMaskedFrame (p : Peer) : Async (UInt8 × ByteArray) := do
  discard <| p.ensure 2
  let hdr ← p.take 2
  let opcode := hdr.get! 0 &&& 0x0F
  let lenField := (hdr.get! 1 &&& 0x7F).toNat
  let mut payloadLen := lenField
  if lenField == 126 then
    discard <| p.ensure 2
    let ext ← p.take 2
    payloadLen := (ext.get! 0).toNat * 256 + (ext.get! 1).toNat
  else if lenField == 127 then
    discard <| p.ensure 8
    let ext ← p.take 8
    let mut n := 0
    for i in [0:8] do n := n * 256 + (ext.get! i).toNat
    payloadLen := n
  discard <| p.ensure 4
  let maskKey ← p.take 4
  discard <| p.ensure payloadLen
  let raw ← p.take payloadLen
  let mut out := ByteArray.empty
  for i in [0:payloadLen] do
    out := out.push (raw.get! i ^^^ maskKey.get! (i % 4))
  return (opcode, out)

/-- Encode one server → client WebSocket frame. Server frames are never masked. -/
private def unmaskedFrame (fin : Bool) (opcode : UInt8) (payload : ByteArray) : ByteArray := Id.run do
  let len := payload.size
  let mut out := ByteArray.empty
  out := out.push (((if fin then 0x80 else 0x00) : UInt8) ||| opcode)
  if len < 126 then
    out := out.push len.toUInt8
  else if len ≤ 0xFFFF then
    out := out.push 126
    out := out.push ((len / 256) % 256).toUInt8
    out := out.push (len % 256).toUInt8
  else
    out := out.push 127
    for i in [0:8] do
      let shift := (7 - i) * 8
      out := out.push ((len >>> shift) % 256).toUInt8
  return out ++ payload

/-- Server-side RFC 6455 handshake: read the request up to the blank line,
pull `Sec-WebSocket-Key`, answer `101` with the matching `Sec-WebSocket-Accept`. -/
private def Peer.doHandshake (p : Peer) : Async Unit := do
  let reqHeader ← p.readUntil "\r\n\r\n".toUTF8
  let lines := (String.fromUTF8! reqHeader).splitOn "\r\n"
  let some keyLine := lines.find? (fun l => l.toLower.startsWith "sec-websocket-key:")
    | throw <| .userError "Mocks: no Sec-WebSocket-Key in request"
  let key := String.ofList
    ((((keyLine.splitOn ":").drop 1).headD "").toList.dropWhile (· == ' '))
  let accept := WebSocket.expectedAccept key
  let resp :=
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    s!"Sec-WebSocket-Accept: {accept}\r\n\r\n"
  p.client.send resp.toUTF8

/--
Accept one connection, perform the server-side handshake, then echo
every text/binary message back split into two continuation frames,
exercising the client's fragment-reassembly path. After the first
data message, also sends an unsolicited `Ping`, to check the client
answers with a `Pong` on its own. Stops on `Close`.

The client never fragments what it sends, so `recvMaskedFrame`'s fin
bit goes unused here. Returns whether the expected `Pong("pingdata")`
was observed; this loops over raw frames and dispatches on opcode
rather than assuming a fixed arrival order, since the `Pong` can
interleave with the second data message either way.
-/
partial def runEchoServerOnce (srv : TCP.Socket.Server) : Async Bool := do
  let client ← srv.accept
  let buf ← IO.mkRef ByteArray.empty
  let p : Peer := ⟨client, buf⟩
  p.doHandshake
  let msgCount ← IO.mkRef 0
  let sawPong ← IO.mkRef false
  let rec loop : Async Bool := do
    let (opcode, payload) ← p.recvMaskedFrame
    if opcode == 0x8 then
      client.send (unmaskedFrame true 0x8 ByteArray.empty)
      return (← sawPong.get)
    else if opcode == 0xA then
      if payload == "pingdata".toUTF8 then sawPong.set true
      loop
    else if opcode == 0x1 || opcode == 0x2 then
      let mid := payload.size / 2
      client.send (unmaskedFrame false opcode (payload.extract 0 mid))
      client.send (unmaskedFrame true 0x0 (payload.extract mid payload.size))
      let n ← msgCount.modifyGet (fun n => (n, n + 1))
      if n == 0 then
        client.send (unmaskedFrame true 0x9 "pingdata".toUTF8)
      loop
    else
      loop
  loop

/--
Accept exactly one connection, read a plain HTTP/1.1 request up to the
blank line (ignoring it entirely -- method, path, headers, all of it),
and answer with a fixed JSON body shaped like Chromium's real
`/json/version`, for `LeanCDP.Discovery` to parse. `wsPort` is baked
into the `webSocketDebuggerUrl` it hands back.
-/
def runHttpJsonServerOnce (srv : TCP.Socket.Server) (wsPort : UInt16) : Async Unit := do
  let client ← srv.accept
  let buf ← IO.mkRef ByteArray.empty
  let p : Peer := ⟨client, buf⟩
  discard <| p.readUntil "\r\n\r\n".toUTF8
  let body :=
    Json.mkObj [
      ("Browser", Json.str "MockChrome/1.0"),
      ("webSocketDebuggerUrl",
        Json.str s!"ws://127.0.0.1:{wsPort}/devtools/browser/mock-uuid")
    ] |>.compress
  let resp :=
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Connection: close\r\n" ++
    s!"Content-Length: {body.toUTF8.size}\r\n\r\n" ++
    body
  client.send resp.toUTF8
  client.shutdown

/--
Accept one connection, perform the handshake, then send one
unsolicited event (`{"method":"Mock.ready","params":{"ok":true}}`,
no `id`) and answer every `{"id","method","params"}` text frame with
`{"id","result":{"echoedMethod","params"}}` -- except method `"Slow"`,
which sleeps 300ms first, to test that two calls answered out of send
order each resolve the correct caller. Stops on `Close`.
-/
partial def runCdpMockServerOnce (srv : TCP.Socket.Server) : Async Unit := do
  let client ← srv.accept
  let buf ← IO.mkRef ByteArray.empty
  let p : Peer := ⟨client, buf⟩
  p.doHandshake
  let readyEvent := Json.mkObj [("method", Json.str "Mock.ready"), ("params", Json.mkObj [("ok", Json.bool true)])]
  client.send (unmaskedFrame true 0x1 readyEvent.compress.toUTF8)
  let rec loop : Async Unit := do
    let (opcode, payload) ← p.recvMaskedFrame
    if opcode == 0x8 then
      client.send (unmaskedFrame true 0x8 ByteArray.empty)
    else if opcode == 0x1 then
      match Json.parse (String.fromUTF8! payload) with
      | .error e => throw <| .userError s!"Mocks.runCdpMockServerOnce: bad JSON from client: {e}"
      | .ok req =>
        let id := req.getObjValD "id"
        let method := req.getObjValD "method"
        let params := req.getObjValD "params"
        if (method.getStr?.toOption.getD "") == "Slow" then
          Std.Async.sleep (300 : Std.Time.Millisecond.Offset)
        let reply := Json.mkObj
          [("id", id), ("result", Json.mkObj [("echoedMethod", method), ("params", params)])]
        client.send (unmaskedFrame true 0x1 reply.compress.toUTF8)
        loop
    else
      loop
  loop

/--
Accept one connection, perform the handshake, send one text frame
containing an invalid UTF-8 byte (`0x80`, a bare continuation byte),
then read the next frame and report whether it was a `Close` carrying
status code 1007.
-/
def runInvalidUtf8ServerOnce (srv : TCP.Socket.Server) : Async Bool := do
  let client ← srv.accept
  let buf ← IO.mkRef ByteArray.empty
  let p : Peer := ⟨client, buf⟩
  p.doHandshake
  let badUtf8 : ByteArray := ByteArray.mk #[0x80]
  client.send (unmaskedFrame true 0x1 badUtf8)
  let (opcode, payload) ← p.recvMaskedFrame
  if opcode != 0x8 || payload.size < 2 then
    return false
  let code := (payload.get! 0).toNat * 256 + (payload.get! 1).toNat
  return code == 1007

/--
Accept one connection and answer the handshake with a
`Sec-WebSocket-Extensions: permessage-deflate` header the client never
offered, so a correct client refuses the connection (RFC 6455 §9.1).
-/
def runExtensionServerOnce (srv : TCP.Socket.Server) : Async Unit := do
  let client ← srv.accept
  let buf ← IO.mkRef ByteArray.empty
  let p : Peer := ⟨client, buf⟩
  let reqHeader ← p.readUntil "\r\n\r\n".toUTF8
  let lines := (String.fromUTF8! reqHeader).splitOn "\r\n"
  let some keyLine := lines.find? (fun l => l.toLower.startsWith "sec-websocket-key:")
    | throw <| .userError "Mocks: no Sec-WebSocket-Key in request"
  let key := String.ofList
    ((((keyLine.splitOn ":").drop 1).headD "").toList.dropWhile (· == ' '))
  let accept := WebSocket.expectedAccept key
  let resp :=
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Extensions: permessage-deflate\r\n" ++
    s!"Sec-WebSocket-Accept: {accept}\r\n\r\n"
  client.send resp.toUTF8

end LeanCDP.Testing
