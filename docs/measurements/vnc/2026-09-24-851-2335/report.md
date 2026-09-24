# 851-2335: ⌘C/⌘V on a real Linux desktop — notes

`validate.md` is the gate's output: PASS (tests 325 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24).

## The check

`scripts/vnc-desktop-shortcuts.sh root@HOST` sends Mac shortcuts through the
viewer's own key mapping (new `screen-sharing-rig vnc-keys`, which uses
`VNCKeyTranslator`: ⌘ is Control_R, letters through a fixed US layout). It
reads the results back over ssh (clipboard with xclip, files on disk).
Contabo, 2026-09-24:

```text
✔ ⌘A ⌘C in Mousepad copies the text
✔ ⌘V ⌘S in Mousepad pastes and saves
✔ ⌘⇧V in the terminal pastes
✔ ⌘⇧A ⌘⇧C in the terminal copies its text
vnc-desktop-shortcuts: PASS
```

Control–Option–Escape leaving control is the viewer's own handling, covered by
the input-surface tests. It doesn't depend on the desktop.

## Things it found, fixed here

- **Xvnc's sign-in blacklist locked out 127.0.0.1.** The desktop scripts
  waited for their ssh tunnel with `nc -z`, and TigerVNC counts each dropped
  probe as a failed sign-in. Five blacklisted 127.0.0.1, which is also where
  codevisor-server connects from, so a product viewer could have been refused
  too.
  - The scripts now use `ssh -f -o ExitOnForwardFailure=yes` with a control
    socket: no probes.
  - `vnc-desktop.sh` runs Xvnc with `-UseBlacklist=0`. It listens on
    localhost only with no password, so there's nothing to brute-force.
  - On Contabo the unit was updated in place (daemon-reload, no restart), so
    the running Xvnc keeps its blacklist until it next restarts. That's
    harmless now that nothing probes.
- **Apps launched from ssh need the session's D-Bus.** From the ssh shell's
  own bus, Mousepad (single-instance) never shows its window. The same trap
  as 851-2330.
- **Anchored pkill patterns.** `pkill -f 'mousepad …'` also matched the ssh
  shell running it and killed it mid-cleanup, which left temp folders
  behind.
- **`xclip -i` stays running** to serve the selection; its output must not
  hold ssh open.

`vnc-desktop.sh` also installs Mousepad, Xfce's editor.
