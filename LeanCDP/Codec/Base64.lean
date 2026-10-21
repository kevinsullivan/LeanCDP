/-
RFC 4648 base64, from scratch. Lean's bundled `Std` doesn't ship it, and
the WebSocket handshake needs it: the client's `Sec-WebSocket-Key`
nonce and the server's expected `Sec-WebSocket-Accept` are both base64
text. Encode is what the handshake actually needs; decode is included
for symmetry and so the round-trip property is testable.
-/

namespace LeanCDP.Codec.Base64

private def alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

/-- Encode `data` as a base64 `String`, `=`-padded to a multiple of 4 characters. -/
def encode (data : ByteArray) : String := Id.run do
  let n := data.size
  let mut out := ""
  let mut i := 0
  while i < n do
    let b0 := data.get! i
    let b1 := if i + 1 < n then data.get! (i + 1) else 0
    let b2 := if i + 2 < n then data.get! (i + 2) else 0
    let n0 := b0.toNat >>> 2
    let n1 := ((b0.toNat % 4) <<< 4) ||| (b1.toNat >>> 4)
    let n2 := ((b1.toNat % 16) <<< 2) ||| (b2.toNat >>> 6)
    let n3 := b2.toNat % 64
    out := out.push alphabet[n0]!
    out := out.push alphabet[n1]!
    out := out.push (if i + 1 < n then alphabet[n2]! else '=')
    out := out.push (if i + 2 < n then alphabet[n3]! else '=')
    i := i + 3
  return out

/-- Sentinel for "not a base64 digit" -- one past the valid `0..63` range. -/
private def invalid : Nat := 64

private def decodeTable : Array Nat := Id.run do
  let mut t : Array Nat := Array.replicate 256 invalid
  for i in [0:64] do
    t := t.set! (alphabet[i]!.toNat) i
  return t

/--
Decode base64 text back to bytes. `none` on malformed input (wrong
length, or a character outside the alphabet/padding).
-/
def decode (s : String) : Option ByteArray := Id.run do
  let chars := s.toList.filter (· ≠ '=') |>.toArray
  let padding := s.toList.reverse.takeWhile (· = '=') |>.length
  if (chars.size + padding) % 4 ≠ 0 then return none
  let mut out := ByteArray.empty
  let mut i := 0
  let n := chars.size
  let mut ok := true
  while i < n do
    let get (k : Nat) : Nat :=
      if i + k < n then decodeTable[chars[i + k]!.toNat]! else 0
    let v0 := get 0
    let v1 := get 1
    let v2 := get 2
    let v3 := get 3
    if v0 == invalid then ok := false
    if v1 == invalid then ok := false
    if i + 2 < n then
      if v2 == invalid then ok := false
    if i + 3 < n then
      if v3 == invalid then ok := false
    let b0 : UInt8 := ((v0 <<< 2 ||| v1 >>> 4) % 256).toUInt8
    let b1 : UInt8 := (((v1 % 16) <<< 4 ||| v2 >>> 2) % 256).toUInt8
    let b2 : UInt8 := (((v2 % 4) <<< 6 ||| v3) % 256).toUInt8
    out := out.push b0
    if i + 2 < n then out := out.push b1
    if i + 3 < n then out := out.push b2
    i := i + 4
  return if ok then some out else none

end LeanCDP.Codec.Base64
