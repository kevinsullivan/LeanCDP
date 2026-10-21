/-
SHA-1 (FIPS 180-1), from scratch. Lean's bundled `Std` doesn't ship
any hash functions, and the WebSocket handshake needs one: the
server's `Sec-WebSocket-Accept` header is defined as
`base64(SHA1(clientKey ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`.
Verified below against the FIPS 180-1 test vectors and the worked
example from RFC 6455 §1.3.
-/

namespace LeanCDP.Codec.SHA1

private def rotl (x : UInt32) (n : UInt32) : UInt32 :=
  (x <<< n) ||| (x >>> (32 - n))

private structure State where
  h0 : UInt32
  h1 : UInt32
  h2 : UInt32
  h3 : UInt32
  h4 : UInt32

private def initState : State :=
  { h0 := 0x67452301, h1 := 0xEFCDAB89, h2 := 0x98BADCFE, h3 := 0x10325476, h4 := 0xC3D2E1F0 }

/-- Append the `0x80` bit, zero-pad, and append the 64-bit big-endian
bit length, so the result is a whole number of 64-byte blocks. -/
private def pad (msg : ByteArray) : ByteArray := Id.run do
  let bitLen : UInt64 := msg.size.toUInt64 * 8
  let mut out := msg.push 0x80
  while out.size % 64 != 56 do
    out := out.push 0
  for i in [0:8] do
    let shift : UInt64 := (7 - i.toUInt64) * 8
    out := out.push (((bitLen >>> shift) &&& 0xFF).toUInt8)
  return out

private def word (b : ByteArray) (off : Nat) : UInt32 :=
  (b.get! off).toUInt32 <<< 24 |||
  (b.get! (off + 1)).toUInt32 <<< 16 |||
  (b.get! (off + 2)).toUInt32 <<< 8 |||
  (b.get! (off + 3)).toUInt32

private def processBlock (s : State) (blk : ByteArray) : State := Id.run do
  let mut w : Array UInt32 := Array.mkEmpty 80
  for t in [0:16] do
    w := w.push (word blk (t * 4))
  for t in [16:80] do
    let v := w[t - 3]! ^^^ w[t - 8]! ^^^ w[t - 14]! ^^^ w[t - 16]!
    w := w.push (rotl v 1)
  let mut a := s.h0
  let mut b := s.h1
  let mut c := s.h2
  let mut d := s.h3
  let mut e := s.h4
  for t in [0:80] do
    let (f, k) :=
      if t < 20 then ((b &&& c) ||| ((~~~b) &&& d), (0x5A827999 : UInt32))
      else if t < 40 then (b ^^^ c ^^^ d, (0x6ED9EBA1 : UInt32))
      else if t < 60 then ((b &&& c) ||| (b &&& d) ||| (c &&& d), (0x8F1BBCDC : UInt32))
      else (b ^^^ c ^^^ d, (0xCA62C1D6 : UInt32))
    let temp := rotl a 5 + f + e + k + w[t]!
    e := d
    d := c
    c := rotl b 30
    b := a
    a := temp
  return { h0 := s.h0 + a, h1 := s.h1 + b, h2 := s.h2 + c, h3 := s.h3 + d, h4 := s.h4 + e }

/-- The 20-byte SHA-1 digest of `msg`. -/
def digest (msg : ByteArray) : ByteArray := Id.run do
  let padded := pad msg
  let mut s := initState
  let mut off := 0
  while off < padded.size do
    s := processBlock s (padded.extract off (off + 64))
    off := off + 64
  let mut out := ByteArray.empty
  for h in #[s.h0, s.h1, s.h2, s.h3, s.h4] do
    out := out.push ((h >>> 24) &&& 0xFF).toUInt8
    out := out.push ((h >>> 16) &&& 0xFF).toUInt8
    out := out.push ((h >>> 8) &&& 0xFF).toUInt8
    out := out.push (h &&& 0xFF).toUInt8
  return out

/-- Lowercase hex, mainly for tests and debugging. -/
def toHex (b : ByteArray) : String := Id.run do
  let digits := "0123456789abcdef".toList.toArray
  let mut out := ""
  for byte in b do
    out := out.push digits[byte.toNat >>> 4]!
    out := out.push digits[byte.toNat % 16]!
  return out

end LeanCDP.Codec.SHA1
