/-
The CDP-flavored client: `LeanCDP.Rpc` plus the `LeanCDP.Dialects.cdp`
dialect. Generic at the CDP-method level rather than typed per
domain: `Client.call "Page.navigate" params` works for any of CDP's
hundreds of methods across dozens of domains, rather than hand-written
per-domain wrappers.
-/

import LeanCDP.Rpc
import LeanCDP.Dialects.Cdp

namespace LeanCDP.Protocol

open Lean Std.Async LeanCDP.Rpc

/-- A CDP session: a handshaken WebSocket connection speaking the CDP dialect. -/
structure Client where
  private mk ::
  rpc : Rpc.Client

/-- Connect and perform the WebSocket handshake at the given CDP WebSocket URL path (e.g. the
`webSocketDebuggerUrl` path `LeanCDP.Discovery` reads back from Chromium's `/json/version`). -/
def connect (host : String) (port : UInt16) (path : String) : Async Client := do
  return ⟨← Rpc.connect Dialects.cdp host port path⟩

private def sessionExtra (sessionId? : Option String) : List (String × Json) :=
  match sessionId? with
  | some sid => [("sessionId", Json.str sid)]
  | none => []

private def eventSessionId? (raw : Json) : Option String :=
  (raw.getObjValD "sessionId").getStr?.toOption

/--
Call any CDP method and return its `result` payload, raw. `sessionId?`
addresses the call to a specific target's session (CDP's flat mode,
via `Target.attachToTarget {flatten: true}`) rather than the
browser-wide connection; most of `Page`/`Runtime`/`DOM` require this.
Multiple calls may be in flight at once. Throws on a CDP error
response, or if the connection closes first.
-/
def Client.callWith (c : Client) (sessionId? : Option String) (method : String)
    (params : Json := Json.mkObj []) : Async Json :=
  c.rpc.callWith method params (sessionExtra sessionId?)

/-- Call a browser-wide CDP method (`Target`, `Browser`, ...) -- no session. -/
def Client.call (c : Client) (method : String) (params : Json := Json.mkObj []) : Async Json :=
  c.callWith none method params

/-- Call a CDP method scoped to one target's session (see `callWith`). -/
def Client.callSession (c : Client) (sessionId : String) (method : String)
    (params : Json := Json.mkObj []) : Async Json :=
  c.callWith (some sessionId) method params

/--
Pop and return the oldest queued event: method, session id (`none`
for a browser-wide event), and params. Never blocks.
-/
def Client.pollEvent (c : Client) : Async (Option (String × Option String × Json)) := do
  match ← c.rpc.pollEvent with
  | some (method, raw) => return some (method, eventSessionId? raw, raw.getObjValD "params")
  | none => return none

/-- Block until an event has arrived, then pop and return it. -/
def Client.nextEvent (c : Client) (pollDelayMs : Std.Time.Millisecond.Offset := 50) :
    Async (String × Option String × Json) := do
  let (method, raw) ← c.rpc.nextEvent pollDelayMs
  return (method, eventSessionId? raw, raw.getObjValD "params")

/--
Pop and return the oldest queued event matching `pred method sessionId?
params`, leaving every other queued event in place. See
`Rpc.Client.pollEventMatching`.
-/
def Client.pollEventMatching (c : Client) (pred : String → Option String → Json → Bool) :
    Async (Option (String × Option String × Json)) := do
  match ← c.rpc.pollEventMatching (fun m raw => pred m (eventSessionId? raw) (raw.getObjValD "params")) with
  | some (method, raw) => return some (method, eventSessionId? raw, raw.getObjValD "params")
  | none => return none

/-- Block (by polling, same as `nextEvent`) until an event matching `pred` arrives. -/
def Client.nextEventMatching (c : Client) (pred : String → Option String → Json → Bool)
    (pollDelayMs : Std.Time.Millisecond.Offset := 50) : Async (String × Option String × Json) := do
  let (method, raw) ← c.rpc.nextEventMatching
    (fun m raw => pred m (eventSessionId? raw) (raw.getObjValD "params")) pollDelayMs
  return (method, eventSessionId? raw, raw.getObjValD "params")

/-- Discard every currently queued event matching `pred`, without blocking. -/
def Client.drainEventsMatching (c : Client) (pred : String → Option String → Json → Bool) : Async Unit :=
  c.rpc.drainEventsMatching (fun m raw => pred m (eventSessionId? raw) (raw.getObjValD "params"))

/-- Close the underlying WebSocket connection. `pump` resolves any waiting call to an error. -/
def Client.close (c : Client) : Async Unit := c.rpc.close

end LeanCDP.Protocol
