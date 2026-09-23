# RFB recordings

Real servers' bytes, replayed by `RFBRecordingTests` with no server
(docs/plans/vnc-validation.md: behaviour seen only on a real server becomes
an L1 fixture). Each file is an `RFBRecording` (JSON): `source`, the
framebuffer size after the handshake, the bytes the client read (base64
chunks) and the `expected` outcome of replaying them (updates, SHA-256 of the
final framebuffer's colour bytes, and the pseudo-rectangles and events in
order). Recording starts after authentication, so no credentials are stored.

Record against the pinned TigerVNC container:

```sh
bun run vnc:interop --keep --filter theDesktopArrivesExactlyAsTheServerConfiguredIt  # prints VNC_TEST_PORT
screen-sharing-rig vnc-record --host 127.0.0.1 --port <port> --password codevisor --seconds 3 \
  --pointer 100,100 --source "<server and client description>" --out <name>.json
docker rm -f <container>
```

| Fixture | What it pins |
| --- | --- |
| `tigervnc-1.15-opening.json` | TigerVNC 1.15's opening for a client with every extension: continuous updates confirmed, clipboard caps, the hidden cursor then `left_ptr` after a pointer move, the 1024 × 768 layout, clock ticks as pushed updates |
