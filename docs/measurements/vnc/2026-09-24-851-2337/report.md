# 851-2337: a vnc-bench run failed once without a reason — notes

`validate.md` is the gate's output: PASS (tests 325 + 102, interop 10/10,
bench A/B with no verdicts, tophat 24/24).

## What changed

- On any failure with `--out`, `vnc-bench` writes `bench-error.txt`: the
  failing case and run ("photo/lan run 1: …"), the error, and the last 20
  lines the `vnc-server` process printed. Its stderr is captured and still
  forwarded.
- `vnc:bench` names the output directory even when the origin/main run
  fails, and `vnc:validate` shows either side's `bench-error.txt`, fenced,
  in the report (`benchFailure`, node-tested).

A forced failure (a 40000 × 40000 desktop) records:

```text
typing/lan run 1: the vnc-server for typing didn't report a port within 10 s

vnc-server's last output:
  vnc-server: The VNC server sent an invalid message: framebuffer 40000 × 40000
```

## Reproduction

The original command (`--scenes photo,scroll --profiles lan,constrained
--runs 2 --quality 8`), 20 times in a row with the recording build: **20/20
passed**, no `bench-error.txt`. The one-off failure didn't recur. If it does,
its reason is now kept.
