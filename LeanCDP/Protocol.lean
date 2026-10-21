/-
The CDP wire format: JSON-RPC-shaped but not JSON-RPC 2.0 (no
`"jsonrpc":"2.0"` field, no fixed error-code vocabulary), so this
doesn't use Lean's `Lean.JsonRpc.Message`, which is strict JSON-RPC
2.0 built for the LSP. CDP messages take three shapes:

- a request: `{"id", "method", "params"}`
- a successful response: `{"id", "result"}`
- a failed response: `{"id", "error": {"code", "message"}}`
- an event: `{"method", "params"}`, no `"id"`

This module is generic at the protocol level: `Client.call
"Page.navigate" params` works for any CDP method, rather than typed
per-domain wrappers. `Lean.Json` handles encoding and decoding.

`Client` reads the socket through a single background task (`pump`,
spawned by `connect`), not inside `call`. A response's `id` is matched
against an `IO.Promise` in `pending`; anything with no `id` queues in
`events`. This lets several `call`s be in flight at once, resolved by
`id` regardless of response order, and lets events queue with no call
in flight.
-/

import LeanCDP.WebSocket
import Lean.Data.Json
import Std.Data.HashMap
import Std.Async.Timer

namespace LeanCDP.Protocol

open Lean Std.Async LeanCDP.WebSocket

/-- One parsed CDP message. -/
inductive Message where
  /-- A successful response to request `id`. -/
  | result (id : Nat) (value : Json)
  /-- A failed response to request `id`. -/
  | error (id : Nat) (code : Int) (message : String)
  /-- An unprompted event/notification -- no request `id` of ours to match.
  `sessionId?` is which target's session it belongs to, in flat mode
  (`Target.attachToTarget {flatten: true}`, as `LeanCDP.Page` always uses);
  `none` for a browser-wide event. -/
  | event (method : String) (sessionId? : Option String) (params : Json)
  deriving Inhabited

/-- Classify one incoming JSON value by which of the three CDP shapes it has. -/
def Message.parse (j : Json) : Except String Message := do
  match j.getObjValD "id" with
  | .null =>
    let method ← (j.getObjVal? "method") >>= Json.getStr?
    let sessionId? := ((j.getObjValD "sessionId").getStr?).toOption
    return .event method sessionId? (j.getObjValD "params")
  | idJson =>
    let id ← idJson.getNat?
    match j.getObjValD "error" with
    | .null => return .result id (j.getObjValD "result")
    | errJson =>
      let code := ((errJson.getObjValD "code").getInt?).toOption.getD 0
      let msg := ((errJson.getObjValD "message").getStr?).toOption.getD ""
      return .error id code msg

/--
An open CDP session: a handshaken WebSocket connection, a request-id
counter, a table of in-flight calls keyed by request `id` (`pending`),
and a FIFO of uncollected events (`events`). `pump` is the only reader
of `ws`; everything else goes through `pending`/`events`.
-/
structure Client where
  private mk ::
  ws : WebSocket.Connection
  private nextId : IO.Ref Nat
  private pending : IO.Ref (Std.HashMap Nat (IO.Promise (Except String Json)))
  private events : IO.Ref (Array (String × Option String × Json))

/-- Resolve the promise for `id`, if `call`/`callWith` is still waiting on it, and forget it either way. -/
private def Client.resolvePending (c : Client) (id : Nat) (result : Except String Json) : Async Unit := do
  match (← c.pending.get).get? id with
  | some promise =>
    IO.Promise.resolve result promise
    c.pending.modify (·.erase id)
  | none => pure ()  -- no one is (or ever was) waiting on this id; nothing to do

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
        match Message.parse j with
        | .error _ => loop  -- JSON, but none of the three CDP shapes; ignore
        | .ok (.event method sessionId? params) => c.events.modify (·.push (method, sessionId?, params)); loop
        | .ok (.result id value) => c.resolvePending id (.ok value); loop
        | .ok (.error id code msg) => c.resolvePending id (.error s!"CDP error {code}: {msg}"); loop
  loop

/-- Connect and perform the WebSocket handshake at the given CDP WebSocket URL path (e.g. the
`webSocketDebuggerUrl` path `LeanCDP.Discovery` reads back from Chromium's `/json/version`). -/
def connect (host : String) (port : UInt16) (path : String) : Async Client := do
  let ws ← WebSocket.connect host port path
  let c : Client := ⟨ws, ← IO.mkRef 1, ← IO.mkRef {}, ← IO.mkRef #[]⟩
  discard <| (pump c).asTask
  return c

/--
Call any CDP method and return its `result` payload, raw. `sessionId?`
addresses the call to a specific target's session (CDP's flat mode,
via `Target.attachToTarget {flatten: true}`) rather than the
browser-wide connection; most of `Page`/`Runtime`/`DOM` require this.
Request ids are unique across the connection, so `pump` correlates a
response by `id` alone, session-scoped or not.

Multiple calls may be in flight at once: each gets its own `id` and
promise, resolved in whatever order responses arrive. Throws on a CDP
error response, or if the connection closes first.
-/
def Client.callWith (c : Client) (sessionId? : Option String) (method : String)
    (params : Json := Json.mkObj []) : Async Json := do
  let id ← c.nextId.modifyGet (fun n => (n, n + 1))
  let promise ← IO.Promise.new
  c.pending.modify (·.insert id promise)
  let fields := [("id", Json.num id), ("method", Json.str method), ("params", params)] ++
    (match sessionId? with
      | some sid => [("sessionId", Json.str sid)]
      | none => [])
  c.ws.sendText (Json.mkObj fields).compress
  match ← MonadAwait.await promise with
  | .ok value => return value
  | .error e => throw <| .userError s!"LeanCDP.Protocol.Client.call: {e}"

/-- Call a browser-wide CDP method (`Target`, `Browser`, ...) -- no session. -/
def Client.call (c : Client) (method : String) (params : Json := Json.mkObj []) : Async Json :=
  c.callWith none method params

/-- Call a CDP method scoped to one target's session (see `callWith`). -/
def Client.callSession (c : Client) (sessionId : String) (method : String)
    (params : Json := Json.mkObj []) : Async Json :=
  c.callWith (some sessionId) method params

/--
Pop and return the oldest queued event: method, session id (`none`
for a browser-wide event), and params. Never blocks -- `none` means
nothing is queued right now.
-/
def Client.pollEvent (c : Client) : Async (Option (String × Option String × Json)) := do
  let arr ← c.events.get
  if arr.isEmpty then return none
  else
    c.events.set (arr.extract 1 arr.size)
    return some arr[0]!

/-- Block until an event has arrived, then pop and return it. Polls `pollEvent` every `pollDelayMs`. -/
partial def Client.nextEvent (c : Client) (pollDelayMs : Std.Time.Millisecond.Offset := 50) :
    Async (String × Option String × Json) := do
  match ← c.pollEvent with
  | some ev => return ev
  | none => Std.Async.sleep pollDelayMs; c.nextEvent pollDelayMs

/--
Pop and return the oldest queued event matching `pred method sessionId?
params`, leaving every other queued event in place. Never blocks --
`none` means nothing matching is queued right now. Lets multiple
consumers share one event queue, each filtering for its own events
(`Page.Session.waitForLoad` uses this to wait on its own session's
`Page.loadEventFired` without consuming anything else).
-/
def Client.pollEventMatching (c : Client) (pred : String → Option String → Json → Bool) :
    Async (Option (String × Option String × Json)) := do
  let arr ← c.events.get
  match arr.findIdx? (fun (m, sid, p) => pred m sid p) with
  | some idx =>
    let ev := arr[idx]!
    c.events.set (arr.eraseIdx! idx)
    return some ev
  | none => return none

/-- Block (by polling, same as `nextEvent`) until an event matching `pred` arrives. -/
partial def Client.nextEventMatching (c : Client) (pred : String → Option String → Json → Bool)
    (pollDelayMs : Std.Time.Millisecond.Offset := 50) : Async (String × Option String × Json) := do
  match ← c.pollEventMatching pred with
  | some ev => return ev
  | none => Std.Async.sleep pollDelayMs; c.nextEventMatching pred pollDelayMs

/-- Discard every currently queued event matching `pred`, without blocking. -/
partial def Client.drainEventsMatching (c : Client) (pred : String → Option String → Json → Bool) :
    Async Unit := do
  match ← c.pollEventMatching pred with
  | some _ => c.drainEventsMatching pred
  | none => return ()

/-- Close the underlying WebSocket connection. `pump` resolves any waiting call to an error. -/
def Client.close (c : Client) : Async Unit := c.ws.close

end LeanCDP.Protocol
