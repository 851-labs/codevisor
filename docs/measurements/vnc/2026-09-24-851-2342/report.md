# 851-2342: sign in to a Mac's VNC with its account — notes

`validate.md` is the gate's output: PASS (tests 339 + 104, interop 10/10,
bench A/B with no verdicts, tophat 24/24). `RigVNCSignInTests` 10 (2 new),
`RFBAppleAuthenticationTests` 9 (1 new).

## What changed

- **`RigVNCCredential`:** an optional username plus a password.
  - Stored in the Keychain as the password itself when there's no username,
    exactly as before, so entries saved earlier read unchanged; as JSON
    otherwise.
  - An empty username means the VNC password.
- **`RigVNCSignIn`** carries the credential through its existing rules:
  saved only after the server accepts it, forgotten when rejected, cleared by
  Forget Password.
- **`VNCConnection.securityTypes(host:port:)`** reads the security types a
  server offers from the start of a handshake it then drops.
- **The rig's sign-in form** asks for a **user name and password** when the
  Mac offers account sign-in (type 30), otherwise the VNC password as before.
  An empty user name falls back to the VNC password. A footer explains why
  signing in as the Mac's user matters.
- **Connection:** the rig connects with the credential's username, so type 30
  is used (851-2341).

## Scope

The app never connects to a Mac's VNC server directly (always through
codevisor-server's socket route, with no VNC password), so the form is the
rig's.

## The unlock spike (851-2341)

Ready for the user: in the rig, tuftlord → View → Forget Password, then sign
in with tuftlord's macOS user name and password while it's locked, and see
whether it unlocks. I haven't done this myself: it clears the stored VNC
password and needs the account's password.
