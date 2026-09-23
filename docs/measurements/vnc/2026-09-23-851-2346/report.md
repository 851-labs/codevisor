# 851-2346: pointer disappears over the VNC desktop after ⌘Tab — notes

`validate.md` is the gate's output: PASS (tests 325 + 101, interop 10/10,
bench A/B with no verdicts, tophat 24/24). Viewer suites
(`ScreenSharingInputSurface|ScreenSharingVideoSurface|ScreenSharingKeyboardCapture`):
44 passed, including the two new tests.

## Evidence

alexandru's recording (Contabo, Control mode), extracted at 4 fps: the arrow
shows over the sidebar and vanishes over the video. The sidebar selection
flips between key (blue) and inactive (grey) as the app is ⌘Tabbed.

## Cause

- `ScreenSharingInputSurface` suspends on app resign-active, window
  resign-key and menu tracking (`inputFocused = false`, lease kept).
- `resume()` ran only when the video became first responder or on a click in
  it. After ⌘Tab the video never lost first responder, so nothing resumed.
- `ScreenSharingVideoSurface` chose the pointer from `input.active` (the
  lease) alone. It kept installing the host's cursor over the video (a 1×1
  invisible cursor until a shape arrives), while motion was dropped because
  input was suspended. The result: an invisible pointer that moved nothing,
  until a click.

## Fix

- The cursor follows live input (`isLive = active && inputFocused`). While
  suspended, the pointer is the arrow plus the View-mode overlay;
  `suspend`/`resume` re-evaluate it.
- Input resumes when focus really returns (app active, window key, or menu
  closed) and the video is still first responder with nothing modal in front.
  A local editor keeps it suspended.

## Behaviour change

Returning to the app with the video still focused now sends keys to the host
without a click, as in any Mac app whose focused view is still focused. The
old test ("returning to the app alone does not route") still holds for a bare
key-window change without the app/window notifications. If a click should
stay required, drop the three resume observers; the cursor fix stands alone.

## Not covered by automation

⌘Tab itself: the tophat must not take focus from the user's Mac. Hands-on
check: Control mode on Contabo, ⌘Tab away and back; the pointer stays
visible and moves the host's.
