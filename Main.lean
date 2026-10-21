/-
`leancdp-probe`: a smoke test for `LeanCDP.Transport`. Speaks enough
raw HTTP/1.1 to fetch one path from one host and print the response.

Usage: leancdp-probe <ipv4-host> <port> [path]
  e.g. leancdp-probe 127.0.0.1 9222 /json/version
-/

import LeanCDP.Transport

open LeanCDP.Transport Std.Async

def httpGet (host : String) (port : UInt16) (path : String) : Async String := do
  let conn ← connect host port
  let req := s!"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
  conn.send req.toUTF8
  let body ← conn.recvAll
  return String.fromUTF8! body

def main (args : List String) : IO Unit := do
  let (host, port, path) :=
    match args with
    | [h, p]      => (h, p.toNat!.toUInt16, "/")
    | [h, p, pth] => (h, p.toNat!.toUInt16, pth)
    | _           => ("127.0.0.1", (8111 : UInt16), "/")
  IO.println s!"GET http://{host}:{port}{path}"
  let resp ← (httpGet host port path).block
  IO.println s!"-- {resp.length} bytes --"
  IO.println (resp.take 300)
