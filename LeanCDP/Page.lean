/-
Wraps `LeanCDP.Protocol.Client` with the attach/navigate/screenshot/
close choreography most CDP use needs. `Page`, `Runtime`, `DOM`, and
most of the rest of CDP operate on one target (a tab), reached by
attaching in flat session mode (`Target.attachToTarget {flatten:
true}`) and tagging every call with the resulting `sessionId` --
`Client.callSession` does the tagging; this module does the rest.
-/

import LeanCDP.Protocol
import Std.Async.Timer

namespace LeanCDP.Page

open Lean Std.Async LeanCDP.Protocol LeanCDP.Codec

/-- A CDP client attached to one page's session -- the level
`Page.navigate`/`Page.captureScreenshot`/`Runtime.evaluate` operate
at, as opposed to the browser-wide `Target`/`Browser` domains
`Client.call` reaches directly. -/
structure Session where
  private mk ::
  client : Client
  targetId : String
  sessionId : String

/-- Does `method`/`sessionId?` name *this* session's `Page.loadEventFired`? -/
private def Session.isOwnLoadEvent (s : Session) (method : String) (sessionId? : Option String)
    (_params : Json) : Bool :=
  method == "Page.loadEventFired" && sessionId? == some s.sessionId

/-- Create a blank tab, attach to it in flat session mode, and enable
the `Page` domain so Chromium emits `Page.loadEventFired` for it.
Events are forward-only from `Page.enable`; the initial `about:blank`
load isn't replayed. -/
def openBlank (client : Client) : Async Session := do
  let created ← client.call "Target.createTarget" (Json.mkObj [("url", Json.str "about:blank")])
  let some targetId := (created.getObjValD "targetId").getStr?.toOption
    | throw <| .userError "LeanCDP.Page.openBlank: Target.createTarget returned no targetId"
  let attached ← client.call "Target.attachToTarget"
    (Json.mkObj [("targetId", Json.str targetId), ("flatten", Json.bool true)])
  let some sessionId := (attached.getObjValD "sessionId").getStr?.toOption
    | throw <| .userError "LeanCDP.Page.openBlank: Target.attachToTarget returned no sessionId"
  let s : Session := ⟨client, targetId, sessionId⟩
  discard <| client.callSession sessionId "Page.enable"
  return s

/--
Navigate this page to `url`. Returns once Chromium accepts the
navigation, not once the page finishes loading -- see `waitForLoad`.
Drains any already-queued `Page.loadEventFired` for this session
first, so a subsequent `waitForLoad` can't match a stale event from
before this navigation.
-/
def Session.navigate (s : Session) (url : String) : Async Unit := do
  s.client.drainEventsMatching s.isOwnLoadEvent
  discard <| s.client.callSession s.sessionId "Page.navigate" (Json.mkObj [("url", Json.str url)])

/--
Wait for this session's `Page.loadEventFired`, up to `maxAttempts`
polls of the event queue, `delayMs` apart. Throws if it doesn't arrive
within the budget.
-/
partial def Session.waitForLoad (s : Session) (maxAttempts : Nat := 100)
    (delayMs : Std.Time.Millisecond.Offset := 100) : Async Unit := do
  let rec loop (attemptsLeft : Nat) : Async Unit := do
    match ← s.client.pollEventMatching s.isOwnLoadEvent with
    | some _ => return ()
    | none =>
      if attemptsLeft == 0 then
        throw <| .userError
          "LeanCDP.Page.Session.waitForLoad: Page.loadEventFired never arrived within the wait budget"
      else
        Std.Async.sleep delayMs
        loop (attemptsLeft - 1)
  loop maxAttempts

/-- Capture the current page as PNG bytes, decoded from CDP's base64 response. -/
def Session.screenshot (s : Session) : Async ByteArray := do
  let result ← s.client.callSession s.sessionId "Page.captureScreenshot"
  let some b64 := (result.getObjValD "data").getStr?.toOption
    | throw <| .userError "LeanCDP.Page.Session.screenshot: Page.captureScreenshot returned no data"
  let some bytes := Base64.decode b64
    | throw <| .userError "LeanCDP.Page.Session.screenshot: couldn't base64-decode the screenshot data"
  return bytes

/-- Close the tab this session is attached to. -/
def Session.close (s : Session) : Async Unit :=
  discard <| s.client.call "Target.closeTarget" (Json.mkObj [("targetId", Json.str s.targetId)])

end LeanCDP.Page
