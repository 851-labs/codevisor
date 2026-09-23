# 851-2347: the remote cursor goes microscopic on a big desktop — notes

`validate.md` is the gate's output: PASS (tests 325 + 101, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Viewer suites
(`ScreenSharingRemoteCursorTests|ScreenSharingVideoSurface|ScreenSharingInputSurface`):
43 passed.

## Evidence

In alexandru's recording (tuftlord, macOS Screen Sharing, 1720 × 1080
export), the arrow over the sidebar measures ~12 × 18 px; over the video, a
correctly shaped arrow measures ~5 × 7 px.

## Cause

The remote cursor was sized at the video's scale (cursor pixels × points per
remote pixel). A Retina Mac sends its full framebuffer (3000+ px wide) and
doesn't resize to the pane, so in a ~1300-pt pane the scale is ~0.4, and a 1×
cursor on a 2× desktop shrinks further.

## Fix

`ScreenSharingVideoGeometry.cursorScale` = max(video scale, min(1, 20 pt ÷
cursor height)), used by the Control-mode NSCursor and the View-mode overlay:

- never shorter than ~20 pt (the Mac's arrow);
- never enlarged past one point per cursor pixel to get there;
- still grows with a zoomed-in video;
- the hotspot still lands on the host's position at the video's scale.

## Not covered by automation

The Control-mode cursor is the system cursor, which window captures don't
include. At tuftlord's lock screen Apple's server reports no pointer
position, so there's no View-mode overlay to capture either. (The purple dot
in `tuftlord-view` captures is tuftlord's own screen-sharing indicator in its
framebuffer.) Hands-on check: tuftlord in Control mode; the pointer is normal
size.
