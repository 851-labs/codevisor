# Plugins

Codevisor plugins are local HTTP servers. A plugin declares its setup and run commands, panes,
tools, supported platforms, minimum Codevisor version, and required executables in
`codevisor-plugin.json`.

## Install requirements

Remote managed installs require Git. Codevisor does not install Git, Node.js, Ruby, or another
system runtime. A protocol v2 plugin should declare every executable it needs with an installation
hint and help URL; Codevisor checks these requirements before running setup.

Linked development plugins do not require Git. They point at an existing local directory and are
never deleted by Codevisor.

## Updates

Managed registry installs track manifest semantic versions. Codevisor stages an exact registry
commit, validates it, runs setup in staging, and presents its commands, requirements, and pane/tool
changes before applying it. There is no separate update hook: setup must be repeatable and must not
migrate persistent data.

```bash
codevisor plugin updates
codevisor plugin update owner.plugin
```

An update keeps plugin data and enabled state. If startup verification fails, Codevisor restores
the previous code, data, and process automatically.

## Recovery and migration

After a successful update, Codevisor retains one verified pre-update code/data snapshot. Restore it
from the app's plugin menu or with:

```bash
codevisor plugin restore owner.plugin
```

The displaced current version becomes the next restore point, so the operation can be reversed.

Plugins installed before source receipts existed remain usable and show `Source unknown`. Reinstall
the same plugin from its registry source to create a trusted receipt; Codevisor preserves its data
and then enables normal update checks. It never guesses provenance from directory contents.

Disable a plugin without uninstalling it to stop its process and remove its agent tools from the
catalog. Its code, data, panes, update eligibility, and restore point remain installed.

```bash
codevisor plugin disable owner.plugin
codevisor plugin enable owner.plugin
```
