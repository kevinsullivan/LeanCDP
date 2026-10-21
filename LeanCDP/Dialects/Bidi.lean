/-
WebDriver BiDi (https://w3c.github.io/webdriver-bidi/), the protocol
Firefox's `--remote-debugging-port` serves. Commands are
`{"id","method","params"}`, same shape as CDP's -- but every incoming
message carries an explicit `"type"` discriminator
(`"success"`/`"error"`/`"event"`) instead of CDP's implicit
presence-or-absence-of-fields classification:

- a success response: `{"type":"success","id","result"}`
- an error response: `{"type":"error","id","error":"<error code
  string>","message"}` -- `"error"` here is a short code *name*
  (`"invalid session id"`, `"unknown command"`, ...), not the numeric
  code CDP and JSON-RPC 2.0 use; folded into `Envelope.error`'s
  `message` field, with `code` left `0`
- an event: `{"type":"event","method","params"}`

See `LeanCDP.Rpc` for the connection machinery this dialect plugs
into.
-/

import LeanCDP.Rpc

namespace LeanCDP.Dialects

open Lean LeanCDP.Rpc

def bidi : Dialect where
  buildRequest id method params extra :=
    Json.mkObj ([("id", Json.num id), ("method", Json.str method), ("params", params)] ++ extra)
  parse j :=
    match (j.getObjValD "type").getStr?.toOption with
    | some "success" =>
      match (j.getObjValD "id").getNat?.toOption with
      | some id => some (.result id (j.getObjValD "result"))
      | none => none
    | some "error" =>
      match (j.getObjValD "id").getNat?.toOption with
      | none => none
      | some id =>
        let errCode := (j.getObjValD "error").getStr?.toOption.getD ""
        let msg := (j.getObjValD "message").getStr?.toOption.getD ""
        some (.error id 0 s!"{errCode}: {msg}" j)
    | some "event" =>
      match (j.getObjValD "method").getStr?.toOption with
      | some method => some (.event method (j.getObjValD "params") j)
      | none => none
    | _ => none

end LeanCDP.Dialects
