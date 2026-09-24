# 851-2341: Apple account sign-in (security type 30) — notes

`validate.md` is the gate's output: PASS (tests 338 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24). `RFBAppleAuthenticationTests`
(8) and the handshake and loopback suites: 53 passed.

## What changed

- `RFBAppleAuthentication` implements type 30 as noVNC and libvncclient do:
  - the server's generator, key length, prime and public key;
  - a random private key, our public key and the shared secret;
  - AES-128 key = MD5(shared);
  - 128 bytes of credentials (username, then password, each NUL-terminated in
    a 64-byte block with random padding), encrypted AES-128-ECB, then our
    public key.
- `RFBBigUInt`: just enough big-integer arithmetic for it. Montgomery modular
  exponentiation (CIOS, no division) for an odd modulus.
- `RFBHandshake` prefers type 30 when a username (and password) is given and
  offered. Otherwise it keeps VNC Authentication or None as before. A
  3.3-style server that picks 30 is accepted with a username.
  `VNCConnection.open` and `RFBClient.connect` take `username:`.
- The reference server speaks type 30 (RFC 2409's 1024-bit group, an
  `account` in its configuration), so the client is tested end to end with no
  real Mac.

## Tests

- Modular power vs. plain 64-bit arithmetic: 300 random one- and two-limb odd
  moduli with any exponent. Diffie-Hellman agreement on the 1024-bit group;
  `x^0`, `x^1`; byte round trips.
- AES-128: the FIPS-197 C.1 known answer, both ways.
- Malformed parameters are errors: key length, a server key ≥ the prime, a
  generator ≤ 1, credentials ≥ 64 bytes.
- L2: sign-in with the right account (`security == .appleRemoteDesktop`), a
  wrong one fails with the server's reason, and without a username the VNC
  password is used.

## The spike (does it unlock a locked Mac?)

Not run yet. It needs tuftlord's macOS account, which the user types into the
rig's form (851-2342, next). No credentials were handled here.
