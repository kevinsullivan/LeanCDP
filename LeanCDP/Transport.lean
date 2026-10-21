/-
`LeanCDP.Transport`: a thin, dependency-free wrapper over the raw async
TCP sockets Lean 4 already ships (`Std.Async.TCP`, backed by libuv via
`Std.Internal.UV`). No FFI of our own, no external package -- this is
all reachable from a plain `lean_lib` with no `require` line, because
it is already part of the toolchain.

This is the bottom layer of a pure-Lean Chrome DevTools Protocol (CDP)
client. CDP is JSON-RPC carried over a WebSocket; a WebSocket is a
framed protocol carried over a plain TCP connection, after an HTTP
Upgrade handshake. This module provides exactly that last, plain-TCP
piece -- connect, send bytes, receive bytes -- and nothing CDP- or
WebSocket-specific. See the project README for the layers still to be
built on top of it.
-/

import Std.Async.TCP
import Std.Internal.UV.TCP
import Std.Net.Addr
import Std.Async.DNS

namespace LeanCDP.Transport

open Std.Net Std.Async

/--
An open TCP connection to some remote host. Opaque wrapper around the
underlying `Std.Async.TCP.Socket.Client` so callers of this module
never have to know libuv is involved.
-/
structure Connection where
  private mk ::
  client : TCP.Socket.Client

/--
Resolve `host` to an IPv4 address and connect to it on `port`.
Numeric literals (`"127.0.0.1"`) resolve instantly, with no DNS
round trip; anything else goes through `Std.Async.DNS.getAddrInfo`
(restricted to `AddressFamily.ipv4`, same as everywhere else in this
package -- see `WebSocket`/`Discovery`, which only ever hand this
function what `getAddrInfo` or a literal already produced). Throws if
resolution comes back with no IPv4 address at all.
-/
def connect (host : String) (port : UInt16) : Async Connection := do
  let ipv4 ← match IPv4Addr.ofString host with
    | some literal => pure literal
    | none =>
      let addrs ← DNS.getAddrInfo host "" (some .ipv4)
      let some (.v4 resolved) := addrs.find? (fun a => match a with | .v4 _ => true | .v6 _ => false)
        | throw <| .userError s!"LeanCDP.Transport.connect: no IPv4 address found for {host}"
      pure resolved
  let addr := SocketAddress.v4 { addr := ipv4, port := port }
  let client ← TCP.Socket.Client.mk
  client.connect addr
  return ⟨client⟩

/--
Write `data` to the connection, blocking until the kernel has accepted
all of it.
-/
def Connection.send (c : Connection) (data : ByteArray) : Async Unit :=
  c.client.send data

/--
Read up to `size` bytes. `none` means the peer closed the connection
(end of stream); `some bytes` can be a short read -- callers that need
"exactly N bytes" or "until some delimiter" must loop and accumulate,
same as any other raw socket API.
-/
def Connection.recv? (c : Connection) (size : UInt64 := 65536) : Async (Option ByteArray) :=
  c.client.recv? size

/--
Read until the peer closes the connection, accumulating every chunk.
Convenient for simple request/response probes (see `Main.lean`); a
real WebSocket layer will want `recv?` directly so it can frame as
bytes arrive instead of waiting for EOF.
-/
partial def Connection.recvAll (c : Connection) : Async ByteArray := do
  let rec loop (acc : ByteArray) : Async ByteArray := do
    match ← c.recv? with
    | some chunk => loop (acc ++ chunk)
    | none => return acc
  loop .empty

/--
Shut down the write side of the connection (half-close). The peer will
see EOF on its next read. Closing is best-effort: if the peer already
tore down the connection, the shutdown call fails with "socket is not
connected" -- the connection is then exactly as closed as this call
was trying to make it, so that failure is treated as success.
-/
def Connection.close (c : Connection) : Async Unit :=
  try c.client.shutdown catch _ => pure ()

/--
A `Connection` plus a read buffer, for protocols that need "give me
exactly N bytes" or "give me everything up to this delimiter" rather
than `recv?`'s raw, arbitrarily-chunked reads -- which is every
protocol layered on top of a byte stream, since a single `recv?` can
return less than a full frame/header/body, more than one, or a frame
split across two calls. `WebSocket.Connection` and `Discovery.fetchJson` both build on this
instead of each re-deriving it. `recvAll`'s "read until the peer
closes" assumption doesn't hold against an HTTP/1.1 keep-alive peer,
which never closes the connection at all.
-/
structure Buffered where
  private mk ::
  conn : Connection
  private buf : IO.Ref ByteArray

/-- Wrap a `Connection` with a fresh, empty read buffer. -/
def Buffered.of (conn : Connection) : Async Buffered := do
  return ⟨conn, ← IO.mkRef ByteArray.empty⟩

/-- Pull more bytes from the connection into the buffer. `false` means the peer closed. -/
private def Buffered.fill (b : Buffered) : Async Bool := do
  match ← b.conn.recv? with
  | some chunk => b.buf.modify (· ++ chunk); return true
  | none => return false

/-- Read until the buffer holds at least `n` bytes, or the peer closes first. -/
partial def Buffered.ensure (b : Buffered) (n : Nat) : Async Bool := do
  let rec loop : Async Bool := do
    if (← b.buf.get).size ≥ n then return true
    else if ← b.fill then loop else return false
  loop

/-- Take and remove the first `n` bytes of the buffer. Caller must have `ensure`d at least `n` first. -/
def Buffered.take (b : Buffered) (n : Nat) : Async ByteArray := do
  let cur ← b.buf.get
  b.buf.set (cur.extract n cur.size)
  return cur.extract 0 n

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

/-- Read until `delim` appears in the buffer; returns the bytes before it and consumes through it. -/
partial def Buffered.readUntil (b : Buffered) (delim : ByteArray) : Async (Option ByteArray) := do
  let rec loop : Async (Option ByteArray) := do
    let cur ← b.buf.get
    match findSub cur delim with
    | some idx =>
      b.buf.set (cur.extract (idx + delim.size) cur.size)
      return some (cur.extract 0 idx)
    | none => if ← b.fill then loop else return none
  loop

/-- Read until the peer closes the connection, draining the buffer first. -/
partial def Buffered.readToEnd (b : Buffered) : Async ByteArray := do
  let rec loop : Async Unit := do
    if ← b.fill then loop else pure ()
  loop
  b.buf.get

end LeanCDP.Transport
