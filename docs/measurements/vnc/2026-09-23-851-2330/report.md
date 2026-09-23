# 851-2330: Xfce at 2× for the Retina remote desktop — notes

`validate.md` is the gate's output: PASS (tests 321 + 92, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Contabo tophat with
`SCALE=2 scripts/vnc-desktop.sh`: 13/13; `contabo-retina-2x.png` shows the
Retina desktop with the panel, window borders and a terminal at native size
and sharpness.

## Root cause

851-2315 found that setting `Gdk/WindowScalingFactor` "didn't reach new apps".
The setting was fine; the script was writing to the wrong place. A plain ssh
shell has its own D-Bus (root's systemd user bus), so `xfconf-query` there
starts a second xfconfd. Its writes land in the XML files, but the running
session's xfconfd, xfsettingsd and xfwm4 are never notified. Written through
the session's bus (the address in xfce4-panel's environment), the scale
applied at once: a 50 × 8 terminal measured 1036 × 358 px, twice its 1× size.

## What changed

- `scripts/vnc-desktop.sh` sends every desktop setting through the session's
  D-Bus.
- `SCALE=2` sets Xfce's window scaling and the xhdpi window theme; `SCALE=1`
  (the default) sets them back. SCALE=1 undoes only the 2× theme, never a
  theme the user picked.
- When the scale changes, xfdesktop restarts (it reads the scale at start);
  the panel follows live, and apps already open keep their scale until
  reopened. Xvnc and codevisor-server still restart only when their
  configuration changes (checked on Contabo).
- `docs/plans/vnc-viewer.md` documents it.

## Correction to 851-2322

The same cause means 851-2322's "compositor off" reached only the XML file,
not the running xfwm4, until it was applied through the session bus here
(2026-09-23 ~19:40 CEST). That report's "after" samples were therefore taken
with the compositor still on. Its conclusion is unchanged: the drag is
limited by the 0.5–1.5 Mbit/s route (851-2329), which dwarfs any compositor
effect. The compositor is now off for real.

## Contabo now

1× (`SCALE=1`), theme Default, compositor off, 960 × 679. Rerun with
`SCALE=2` when this machine's Retina Remote Desktop setting is turned on.
