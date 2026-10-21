/-
`leancdp-chromium-demo`: runs `LeanCDP` against a real Chromium, which
no mock in `LeanCDP.Testing.Mocks` can stand in for. Not part of
`leancdp-test`; needs a Chromium already listening:

```sh
chromium --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \
  --user-data-dir=/tmp/leancdp-chromium-demo about:blank &
lake exe leancdp-chromium-demo
```

(`--no-sandbox` is needed only in container environments lacking the
user-namespace permissions Chromium's sandbox wants.)

Checks `Browser.getVersion`, `Target.getTargets`, and a full
`LeanCDP.Page` round trip: open a tab, paint it via `Runtime.evaluate`,
screenshot it, and validate the result's PNG signature and size --
the only correctness check available for a screenshot short of a
human looking at it, which the written file also lets you do.
-/

import LeanCDP

open LeanCDP Std.Async Lean

def main (args : List String) : IO Unit := do
  let port : UInt16 := match args with
    | [p] => p.toNat!.toUInt16
    | _ => 9222
  let (host, wsPort, path) ← (Discovery.discoverBrowserWebSocket "127.0.0.1" port).block
  IO.println s!"discovered: ws://{host}:{wsPort}{path}"
  let client ← (Protocol.connect host wsPort path).block

  let version ← (client.call "Browser.getVersion").block
  IO.println s!"Browser.getVersion -> {version.compress}"
  let targets ← (client.call "Target.getTargets").block
  IO.println s!"Target.getTargets  -> {targets.compress}"

  let page ← (Page.openBlank client).block
  IO.println s!"opened page target {page.targetId}, session {page.sessionId}"
  let js :=
    "document.body.style.background='#003366';" ++
    "document.body.style.color='white';" ++
    "document.body.style.fontFamily='sans-serif';" ++
    "document.body.style.padding='40px';" ++
    "document.body.innerHTML='<h1>LeanCDP</h1>" ++
    "<p>Rendered and photographed by pure Lean 4 code.</p>';"
  discard <| (client.callSession page.sessionId "Runtime.evaluate" (Json.mkObj [("expression", Json.str js)])).block
  let png ← (page.screenshot).block
  let pngSig : ByteArray := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].toByteArray
  let isPng := png.size ≥ 8 && png.extract 0 8 == pngSig
  if isPng && png.size > 1000 then
    IO.println s!"Page.captureScreenshot -> {png.size} bytes, valid PNG signature"
  else
    throw <| IO.userError s!"screenshot failed validation: {png.size} bytes, PNG sig {isPng}"
  IO.FS.writeBinFile "chromium-demo-screenshot.png" png
  IO.println "wrote chromium-demo-screenshot.png"
  (page.close).block

  (client.close).block
  IO.Process.exit 0
