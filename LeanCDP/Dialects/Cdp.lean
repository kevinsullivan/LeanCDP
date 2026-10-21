/-
The CDP wire format: JSON-RPC-shaped but not JSON-RPC 2.0 (no
`"jsonrpc":"2.0"` field, no fixed error-code vocabulary). CDP messages
take three shapes:

- a request: `{"id", "method", "params"}`
- a successful response: `{"id", "result"}`
- a failed response: `{"id", "error": {"code", "message"}}`
- an event: `{"method", "params"}`, no `"id"`, plus `"sessionId"` for
  one sent on a target attached in flat mode
  (`Target.attachToTarget {flatten: true}`)

See `LeanCDP.Rpc` for the connection machinery this dialect plugs
into, and `LeanCDP.Protocol` for the CDP-flavored client built on it.
-/

import LeanCDP.Rpc

namespace LeanCDP.Dialects

open Lean LeanCDP.Rpc

def cdp : Dialect where
  buildRequest id method params extra :=
    Json.mkObj ([("id", Json.num id), ("method", Json.str method), ("params", params)] ++ extra)
  parse j :=
    match j.getObjValD "id" with
    | .null =>
      match (j.getObjVal? "method") >>= Json.getStr? with
      | .error _ => none
      | .ok method => some (.event method (j.getObjValD "params") j)
    | idJson =>
      match idJson.getNat? with
      | .error _ => none
      | .ok id =>
        match j.getObjValD "error" with
        | .null => some (.result id (j.getObjValD "result"))
        | errJson =>
          let code := ((errJson.getObjValD "code").getInt?).toOption.getD 0
          let msg := ((errJson.getObjValD "message").getStr?).toOption.getD ""
          some (.error id code msg errJson)

end LeanCDP.Dialects
