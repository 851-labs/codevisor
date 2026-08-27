# User Stories

The product's UI decisions derive from these stories, not the other way
around. The scoping rule they all share:

> **Config is fleet-wide. State is per-machine. Machine-scoped actions
> live on the machine.** A settings pane for a synced plane (harnesses,
> MCPs, skills, plugins) shows the FLEET's configuration as its primary
> object — never "the composer's machine's view" — with each item's
> per-machine reality inline. The Machines section owns per-machine
> operations (sign-in, per-machine disables, install state).

Anything in the UI that no story below needs is a deletion candidate.

## 1. Add a harness

**Sarah enables Codex for her fleet.**

Settings ▸ Agents shows the fleet's agents — one list, no machine
picker. She toggles Codex on. Every machine installs it via its own
install methods; the row shows "installing on 2 machines" while that
happens, then "sign in required" per machine that needs it. She doesn't
sign in from Settings: the next time she opens the composer targeting
any machine, the picker's sign-in row is there. Signing in on her Mac
ferries nothing (Codex ChatGPT logins are single-owner); each machine's
sign-in surfaces where she actually works.

_Failure honesty:_ a machine with no runnable install method says so on
its row ("no install method: needs npm or brew"), and stays visible —
not silently absent.

## 2. Out of tokens → second Claude account

**Dylan hits his Claude usage limit mid-conversation.**

The chat surfaces the limit as a first-class state, with "Switch
account" next to it — not buried in Settings. He adds a second account
(managed profile, its own OAuth) and makes it active. THE CONVERSATION
HE IS IN continues under the new account: the pinned
`session.harnessAccountId` rebinding is explicit — the harness's native
session state lives in the old account's profile, so the rebind starts
a fresh agent session seeded from Codevisor's own transcript. That is
an honest, visible seam ("continuing under Work account"), never a
silent resume that secretly still burns the exhausted account.

New chats follow the active account. Old chats keep their pin until
their account fails, at which point they offer the same one-tap rebind.
Accounts are per-machine state (OAuth is single-owner): the account
switcher always says which machine it is operating on.

_Today's gap:_ pins are permanent; a rate-limited pinned account gives
the user nothing but the wall. This is the machinery change.

## 3. Add an MCP

**Marcus adds a GitHub MCP.**

Settings ▸ MCP Servers is the fleet's list. He adds the server once;
every machine gets it. The row itself answers "where does this
actually work": ready on 3, blocked on the Linux box ("Needs Screen
Recording" for Computer Use is the canonical example — a capability
that cannot sync). Machine-specific disable is the exception flow, one
toggle on the machine's row, stored as an overlay so "no overlay"
remains the fleet's normal state.

## 4. Install a plugin / remove a skill

**Priya installs a registry plugin and deletes an old skill.**

One action, fleet-wide. The plugin's row reports per machine: ready,
or blocked with the pass's real reason ("needs ffmpeg") that clears
itself when the requirement appears. Linked/dev plugins say
"machine-only" — honestly outside the sync story, not mysteriously
missing elsewhere. Removing a skill tombstones it everywhere; no
machine resurrects it.

## 5. A machine goes dark

**Dylan's Mac Studio loses its direct route.**

Nothing duplicates and nothing disappears. The roster keeps ONE entry:
reachable "via Codevisor Cloud" when the relay works (traffic
transparently re-routes), plainly "Unreachable" when nothing does.
Fleet matrices keep showing the machine's last reported state — stale
is labeled, not hidden. A chat mid-flight on that machine surfaces the
break as the chat's state with a retry, and resumes when the machine
returns; queued config changes (enable a harness, add an MCP) converge
when it's back. Powering a machine off is a normal event, not an error.

## 6. Second machine, zero config

**Sarah adds a Linux server.** (Phase 25's acceptance story.)

One install command, `codevisor setup`, sign in to Codevisor Cloud.
Done. The machine appears on her other devices; harnesses install
themselves to match the fleet; static credentials (API keys) ferry in;
OAuth harnesses appear as sign-in rows in the composer when she first
targets the machine. The matrices show the convergence happening. She
never edits a config file, never re-declares her fleet, never signs in
to anything she didn't have to.

---

## What these stories delete or change (consolidation phase)

- Settings panes stop following the composer-selected machine; the
  Agents machine picker goes away. Fleet-first lists, per-item machine
  status, machine pages for machine ops. One scoping model.
- The three per-machine "On Your Machines" disclosure sections and the
  three readiness planes' client/server code collapse into ONE generic
  machine-report mechanism (namespace-parameterized publisher, parser,
  and section view).
- Session→account pinning becomes rebindable (story 2), with the
  transcript-seeded fresh-session seam made explicit in the UI.
- Machine references stop silently falling back to `.local` anywhere;
  resolution failures are typed and visible (the class of bug that
  poisoned the capability cache).
- Fallbacks that HIDE wrongness are removed; degraded modes that
  SURFACE state (relay failover, stale-labeled matrices) stay.
