import Lake
open Lake DSL

-- No `require`s on purpose: everything this package needs (async TCP
-- sockets over libuv) ships inside the Lean 4 toolchain itself, as
-- `Std.Async`/`Std.Internal.UV`. See README.md for why that matters.
package «lean-cdp»

@[default_target]
lean_lib «LeanCDP» where

lean_exe «leancdp-probe» where
  root := `Main

lean_exe «leancdp-test» where
  root := `Tests

lean_exe «leancdp-chromium-demo» where
  root := `ChromiumDemo

lean_exe «leancdp-screenshot» where
  root := `Screenshot
