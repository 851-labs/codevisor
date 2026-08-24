# Plugin updates

Status: accepted

This document defines the plugin update contract. Implementation commits may add detail, but they
must preserve these guarantees.

## Product behavior

- Codevisor offers manual updates for managed plugins installed from the public registry.
- The manifest's semantic version decides whether an update exists. A changed commit with the same
  version does not create an update.
- Registry installs without an explicit ref track the registry. Explicit refs, arbitrary Git
  remotes, managed local clones, and linked development directories are pinned.
- Updating replaces managed plugin code. It does not call uninstall or delete pane records,
  persistent data, enabled state, or install history.
- Codevisor does not install Git, Node.js, or another system runtime. It checks declared
  requirements before setup and reports concrete installation guidance when one is missing.
- Remote managed installs require Git. Linked development plugins do not.
- Automatic updates remain out of scope until manual updates and rollback have proved reliable.

## Manifest compatibility

Codevisor continues to read protocol v1 manifests. Protocol v2 adds:

- strict semantic versions;
- structured argument arrays for setup and run commands;
- a minimum Codevisor version;
- declared executable requirements; and
- optional platform filters on setup steps.

Protocol v1 shell commands remain supported as legacy behavior. New plugins should publish v2.

Setup prepares the staged code for both installation and update. Codevisor provides the reason,
previous version, and candidate version through environment variables. Plugins do not receive a
separate update hook. Setup must be repeatable and must not migrate persistent data.

## Source identity

Every managed install records a receipt with its source, requested ref, repository subpath,
resolved commit, installed version, and timestamps. The existing managed marker remains the sole
authority for deleting a directory.

The public registry resolves a repository's default branch to an exact commit, reads the manifest
from that commit, and publishes the same commit with the entry. An update always installs the exact
candidate the user reviewed.

Managed plugins installed before receipts exist remain usable. Their update state is
`sourceUnknown` until the user reinstalls them from a known source.

## Transaction guarantees

Installation and update use one prepare-and-apply pipeline:

1. Fetch and validate an exact candidate in hidden staging.
2. Check platform, Codevisor version, Git, and declared executables.
3. Run setup in staging while the installed plugin remains available.
4. Re-read the manifest and reject setup that changes it.
5. Stop the installed process and snapshot persistent data.
6. Atomically exchange the installed and staged code.
7. Start the candidate and wait for its health check.
8. Restore code, data, and the old process if verification fails.

Each plugin permits one mutating operation at a time. A journal lets startup finish or reverse an
interrupted transaction. Codevisor retains one known-good backup for an explicit restore.

## Update states

Clients render one of these states:

- `current`: the installed version matches or exceeds the registry version;
- `available`: the registry has a newer compatible semantic version;
- `pinned`: the source does not track registry updates;
- `incompatible`: a newer version exists but fails a platform or Codevisor requirement;
- `sourceUnknown`: a legacy managed install has no receipt; or
- `checkFailed`: Codevisor could not obtain current registry metadata.

An update begins with a prepared plan. The plan identifies the exact commit and shows version,
command, requirement, pane, and tool changes. Applying the plan uses its staged bytes instead of
fetching a mutable source again.

## Deferred work

Archive transport, artifact signatures, unattended updates, and runtime installation remain
deferred. Codevisor will consider them only after manual update telemetry identifies a concrete
need.
