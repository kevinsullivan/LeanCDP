/-
A generic client for WebSocket-transported RPC protocols shaped like
JSON-RPC: a request is `{"id","method","params", ...}`; a response is
a success or an error keyed by that same `id`; anything with no `id`
is an event. CDP (`LeanCDP.Protocol`) and JSON-RPC 2.0
(`LeanCDP.Dialects.jsonRpc2`) are both instances of this shape, with
different request framing and different error envelopes -- a
`Dialect` is what tells this module which.

A single background reader per `Client` (`pump`, spawned by
`connect`) dispatches responses to the matching call by `id` via a
table of `IO.Promise`s, so any number of calls can be in flight at
once, and queues anything with no `id` as an event. Neither of those
depends on which dialect is in play.
-/

import LeanCDP.WebSocket
import Lean.Data.Json
import Std.Data.HashMap
import Std.Async.Timer

namespace LeanCDP.Rpc

open Lean Std.Async LeanCDP.WebSocket

/--
One classified incoming message. `raw` is the message's full JSON,
kept alongside so a dialect-specific caller can pull out fields this
module doesn't interpret itself (CDP's `sessionId`, say).
-/
inductive Envelope where
  | result (id : Nat) (value : Json)
  | error (id : Nat) (code : Int) (message : String) (raw : Json)
  | event (method : String) (params : Json) (raw : Json)
  deriving Inhabited

/--
How to speak one particular RPC wire format over the WebSocket
`Client` provides. `buildRequest` gets the request `id` this client
assigned, the method and params the caller gave, and any extra
top-level fields the caller wants attached (CDP's `sessionId`, e.g.).
`parse` classifies one incoming JSON value; `none` means "not a
message this dialect recognizes," which `pump` ignores.
-/
structure Dialect where
  buildRequest : Nat → String → Json → List (String × Json) → Json
  parse : Json → Option Envelope

/--
An open RPC session: a handshaken WebSocket connection, the `Dialect`
speaking over it, a request-id counter, a table of in-flight calls
keyed by request `id` (`pending`), and a FIFO of uncollected events
(`events`). `pump` is the only reader of `ws`; everything else goes
through `pending`/`events`.
-/
structure Client where
  private mk ::
  ws : WebSocket.Connection
  dialect : Dialect
  private nextId : IO.Ref Nat
  private pending : IO.Ref (Std.HashMap Nat (IO.Promise (Except String Json)))
  private events : IO.Ref (Array (String × Json))

/-- Resolve the promise for `id`, if `call`/`callWith` is still waiting on it, and forget it either way. -/
private def Client.resolvePending (c : Client) (id : Nat) (result : Except String Json) : Async Unit := do
  match (← c.pending.get).get? id with
  | some promise =>
    IO.Promise.resolve result promise
    c.pending.modify (·.erase id)
  | none => pure ()

/--
Reads `c.ws` for the lifetime of the connection. Dispatches a
`result`/`error` to the matching `pending` promise, if any (a response
to an `id` nobody is waiting on is dropped), and appends an `event` to
the queue. On disconnect, resolves every still-pending promise to an
error, so no `call` blocks forever.
-/
private partial def pump (c : Client) : Async Unit := do
  let rec loop : Async Unit := do
    match ← c.ws.recvMessage with
    | none =>
      for (_, promise) in (← c.pending.get).toList do
        IO.Promise.resolve (Except.error "connection closed") promise
      c.pending.set {}
    | some (_, payload) =>
      match Json.parse (String.fromUTF8! payload) with
      | .error _ => loop  -- not JSON at all; ignore and keep reading
      | .ok j =>
        match c.dialect.parse j with
        | none => loop  -- not a message this dialect recognizes; ignore
        | some (.event method _params raw) => c.events.modify (·.push (method, raw)); loop
        | some (.result id value) => c.resolvePending id (.ok value); loop
        | some (.error id code message _) => c.resolvePending id (.error s!"error {code}: {message}"); loop
  loop

/-- Connect, perform the WebSocket handshake, and start `pump` speaking `dialect`. -/
def connect (dialect : Dialect) (host : String) (port : UInt16) (path : String) : Async Client := do
  let ws ← WebSocket.connect host port path
  let c : Client := ⟨ws, dialect, ← IO.mkRef 1, ← IO.mkRef {}, ← IO.mkRef #[]⟩
  discard <| (pump c).asTask
  return c

/--
Call `method` with `params`, tagged with whatever `extra` top-level
fields the dialect wants attached, and return its result. Multiple
calls may be in flight at once: each gets its own `id` and promise,
resolved in whatever order responses arrive. Throws on an error
response, or if the connection closes first.
-/
def Client.callWith (c : Client) (method : String) (params : Json := Json.mkObj [])
    (extra : List (String × Json) := []) : Async Json := do
  let id ← c.nextId.modifyGet (fun n => (n, n + 1))
  let promise ← IO.Promise.new
  c.pending.modify (·.insert id promise)
  c.ws.sendText (c.dialect.buildRequest id method params extra).compress
  match ← MonadAwait.await promise with
  | .ok value => return value
  | .error e => throw <| .userError s!"LeanCDP.Rpc.Client.call: {e}"

/-- `callWith` with no extra fields. -/
def Client.call (c : Client) (method : String) (params : Json := Json.mkObj []) : Async Json :=
  c.callWith method params []

/-- Pop and return the oldest queued event: method and the message's full JSON. Never blocks. -/
def Client.pollEvent (c : Client) : Async (Option (String × Json)) := do
  let arr ← c.events.get
  if arr.isEmpty then return none
  else
    c.events.set (arr.extract 1 arr.size)
    return some arr[0]!

/-- Block until an event has arrived, then pop and return it. Polls `pollEvent` every `pollDelayMs`. -/
partial def Client.nextEvent (c : Client) (pollDelayMs : Std.Time.Millisecond.Offset := 50) :
    Async (String × Json) := do
  match ← c.pollEvent with
  | some ev => return ev
  | none => Std.Async.sleep pollDelayMs; c.nextEvent pollDelayMs

/--
Pop and return the oldest queued event matching `pred method raw`,
leaving every other queued event in place. Never blocks -- `none`
means nothing matching is queued right now. Lets multiple consumers
share one event queue, each filtering for its own events.
-/
def Client.pollEventMatching (c : Client) (pred : String → Json → Bool) :
    Async (Option (String × Json)) := do
  let arr ← c.events.get
  match arr.findIdx? (fun (m, raw) => pred m raw) with
  | some idx =>
    let ev := arr[idx]!
    c.events.set (arr.eraseIdx! idx)
    return some ev
  | none => return none

/-- Block (by polling, same as `nextEvent`) until an event matching `pred` arrives. -/
partial def Client.nextEventMatching (c : Client) (pred : String → Json → Bool)
    (pollDelayMs : Std.Time.Millisecond.Offset := 50) : Async (String × Json) := do
  match ← c.pollEventMatching pred with
  | some ev => return ev
  | none => Std.Async.sleep pollDelayMs; c.nextEventMatching pred pollDelayMs

/-- Discard every currently queued event matching `pred`, without blocking. -/
partial def Client.drainEventsMatching (c : Client) (pred : String → Json → Bool) : Async Unit := do
  match ← c.pollEventMatching pred with
  | some _ => c.drainEventsMatching pred
  | none => return ()

/-- Close the underlying WebSocket connection. `pump` resolves any waiting call to an error. -/
def Client.close (c : Client) : Async Unit := c.ws.close

end LeanCDP.Rpc
