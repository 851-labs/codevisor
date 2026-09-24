# 851-2341 — fast account sign-in

Signing in to tuftlord with a macOS account (security type 30) took 86 s in
the debug rig before the picture appeared.

## Cause

tuftlord offers a 4096-bit Diffie-Hellman group. The client used a secret
exponent as long as the group (4096 bits), with 32-bit limbs and an array
allocation per Montgomery multiply. In a debug build one power took about
13 s; the rig signs in three times per connect (a credential check, then the
viewer's connections), each with two powers.

## Fix

- Secret exponent: 512 bits (or the group's size if smaller). About twice the
  ~150-bit security level of a 4096-bit group, the usual choice.
- `RFBBigUInt`: 64-bit limbs, and a pointer-based Montgomery multiply that
  allocates nothing and may write in place.

## Measurements (tuftlord, debug rig)

|                                                  |               before |  after |
| ------------------------------------------------ | -------------------: | -----: |
| one 4096-bit power, 512-bit exponent, `-Onone`   | 1.7 s (32-bit limbs) | 0.47 s |
| same, `-O`                                       |                26 ms |      – |
| key exchange per connection (reply after params) |                ~27 s |  1.0 s |
| Reconnect → first picture bytes                  |                 86 s |  5.9 s |

Timeline of one Reconnect after the fix (netstat, 50 ms polling): three
connections, each signed in within 1.7 s; picture data from 5.9 s.

## Tests

- `fermatHoldsForTheRealPrime`: g^(p−1) = 1 and g^p = g on the 1024-bit
  prime, through every limb of the multiply.
- `aMacsFourThousandBitGroupUsesAFiveHundredBitExponent`: exponent length
  rule; a 4096-bit group's reply is 128 + 512 bytes and carries g^secret.
- Existing arithmetic, agreement and loopback sign-in tests unchanged and
  green. The suite runs in 0.6 s (11 s with the first version of the test).

`vnc:validate`: PASS (validate.md); no bench metric outside the noise band.

## Also

- Rig subtitle for tuftlord no longer says "(VNC password)".
- Follow-up: the viewer opens the VNC connection twice per connect, so a Mac
  account sign-in (DH) runs twice; worth one connection.
- Still open for this issue: whether account sign-in unlocks a locked Mac.
