/-
`leancdp-screenshot`: a CLI built on `LeanCDP.Page`. Point it at a URL
and a running Chromium, get a PNG.

Usage: leancdp-screenshot <url> [outfile] [cdp-host] [cdp-port]
  e.g. leancdp-screenshot http://127.0.0.1:8111/index.html shot.png

Needs a Chromium already listening on `--remote-debugging-port`
(default 9222) -- see `README.md` for the launch command.
-/

import LeanCDP

open LeanCDP Std.Async

def main (args : List String) : IO Unit := do
  let (url, outfile, cdpHost, cdpPort) :=
    match args with
    | [url]                         => (url, "screenshot.png", "127.0.0.1", (9222 : UInt16))
    | [url, outfile]                => (url, outfile, "127.0.0.1", (9222 : UInt16))
    | [url, outfile, host]          => (url, outfile, host, (9222 : UInt16))
    | [url, outfile, host, port]    => (url, outfile, host, port.toNat!.toUInt16)
    | _ => ("http://127.0.0.1:8111/index.html", "screenshot.png", "127.0.0.1", (9222 : UInt16))

  let runAll : Async Unit := do
    let (host, wsPort, path) ← Discovery.discoverBrowserWebSocket cdpHost cdpPort
    let client ← Protocol.connect host wsPort path
    let page ← Page.openBlank client
    page.navigate url
    page.waitForLoad
    let png ← page.screenshot
    IO.FS.writeBinFile outfile png
    IO.println s!"wrote {png.size} bytes to {outfile}"
    page.close
    client.close

  IO.println s!"GET {url} via Chromium at {cdpHost}:{cdpPort} -> {outfile}"
  runAll.block
  IO.Process.exit 0
