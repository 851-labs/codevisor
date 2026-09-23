# vnc-bench: time-paced scenes and a new baseline — notes

Follow-up to 851-2310, done before 851-2312 (continuous updates) so that
change is measured against a fair baseline. `validate.md` here is the gate on
this change: PASS, with the bench layer an A/A run against the new baseline.

## Why

`vnc-bench` played a scene frame whenever the client asked, so it measured the
maximum request-driven rate. With continuous updates the client stops asking
and the server pushes as the screen changes, so scenes must change at a fixed
pace, like a real app: `vnc-server --scene-fps N`, `vnc-bench --pace N`
(default 60; `--pace 0` keeps the old request-driven mode). A frame the
client hasn't taken yet holds the scene back, as a real server coalesces.

## New baseline (request/response client, 60 fps scenes)

`docs/measurements/vnc/baseline-Mac16_6.json`. Headline figures:

| scene  | profile      | updates/s | update p50 |    input p50 |
| ------ | ------------ | --------: | ---------: | -----------: |
| typing | lan          |      61.2 |    16.2 ms |            – |
| typing | wan150       |      6.16 |     162 ms |            – |
| scroll | lan          |      61.4 |    16.2 ms |            – |
| scroll | wan150       |      5.79 |     172 ms |            – |
| photo  | lan          |      15.5 |      64 ms |            – |
| photo  | wan150       |      1.34 |     749 ms |            – |
| input  | lan / wan150 |         – |          – | 3.4 / 164 ms |

On `lan` the client keeps up with the app's 60 fps; on `wan150` it is capped
at about one update per round trip (~6/s): the gap 851-2312 closes.

## Noise band

The first A/A run flagged typing/lan CPU per update 0.47 → 0.91 ms: with
paced scenes each update is followed by ~16 ms of idle waiting, and the
baseline's own spread for that metric was ±56 %. CPU per update now has a
0.5 ms absolute floor; the second A/A run passes with no verdicts.
