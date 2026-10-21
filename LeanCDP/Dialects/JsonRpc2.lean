/-
Strict JSON-RPC 2.0 (https://www.jsonrpc.org/specification): requests
and responses carry `"jsonrpc":"2.0"`; errors are
`{"code","message","data"?}`.

Lean's compiler ships its own JSON-RPC 2.0 types,
`Lean.Data.JsonRpc.Message`, built for the LSP over stdio. Not reused
here: its `FromJson Message` instance requires the error `code` to be
one of a fixed, LSP-specific set (`Lean.JsonRpc.ErrorCode`, which
includes Lean-only codes like `rpcNeedsReconnect`) and throws on
anything else -- which breaks against any server using its own
application-level error codes, as the JSON-RPC 2.0 spec explicitly
permits (codes outside -32768..-32000 are reserved for application
use).

See `LeanCDP.Rpc` for the connection machinery this dialect plugs
into.
-/

import LeanCDP.Rpc

namespace LeanCDP.Dialects

open Lean LeanCDP.Rpc

def jsonRpc2 : Dialect where
  buildRequest id method params extra :=
    Json.mkObj ([("jsonrpc", Json.str "2.0"), ("id", Json.num id),
      ("method", Json.str method), ("params", params)] ++ extra)
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
