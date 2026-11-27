# codevisor-server

## Linux desktops

### Setting one up

`codevisor desktop setup` gives a Linux machine a desktop that the Codevisor apps can view. The command talks to the running server, and the server does the work as its own account, so the desktop, its config and its boot service always belong to the account the server runs as.

| Command                    | What it does                                                                                                                                                                                   |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `codevisor desktop setup`  | Installs what is missing, starts the desktop now and at boot, and shares it. Safe to run again.                                                                                                |
| `codevisor desktop status` | Says whether a desktop is set up and running, as which account, and where its log is.                                                                                                          |
| `codevisor desktop remove` | Stops the desktop, closing everything open in it, and stops sharing it. Packages stay installed. A desktop Codevisor didn't set up is only unshared, after its own question, and left running. |
| `codevisor desktop run`    | Runs the desktop in the foreground. The boot service uses this; nobody types it.                                                                                                               |

What setup does, in order:

1. **Looks at the machine** (`GET /v1/desktop`): which of `Xvnc`, `startxfce4`, `xfconf-query`, `dbus-run-session`, `xclip` and `python3` are missing, and what kind of sudo the server's account has. The command itself looks for a desktop an older Codevisor left running as root.
2. **Replaces an older root desktop**, after asking once (or with `--yes`, which answers yes to all of setup's questions). That desktop listens on a local port any account can reach; it is recognised by the system unit the old script wrote (`vncserver@.service`, "Codevisor desktop"). Every instance of it is stopped, enabled or only started by hand, before the unit file is removed, and setup stops with what is left if a root X server from it is still running afterwards. Declining leaves everything as it is.
3. **Installs packages**, the only step that needs root, with the system's own package manager (table below). When every program is already there, there is no root step and nothing asks for sudo. On a system whose package manager isn't known or can't be used (no such program, or the system's files are read-only as on Fedora Atomic, MicroOS and SteamOS), setup says once which programs to install and stops with exit code 1 before it changes anything, the older root desktop included; once they are installed by hand, setup carries on from step 4.
4. **Starts the desktop** (`POST /v1/desktop/start`): the server writes `screen-sharing.json` in its own data folder and a systemd user unit, `codevisor-desktop.service`, and waits until the desktop's session has stayed up: the runner writes a mark next to the socket three seconds after the session started, and a desktop whose session keeps dying is reported as not started, with its log. A name or size already in the config is kept. The display number in the config is kept while it is free or held by this desktop's own X server; otherwise the next free one is taken. A config that Codevisor didn't write (any `screen-sharing.json` without the `service` key setup records, readable or not) is only replaced after asking (`?replace=1`), whether or not that desktop is up at the moment; it keeps running, unshared. There is one desktop unit per account: a second Codevisor server on the same account, with another data folder, leaves it alone and says so.

Who runs the root steps depends on the sudo the server's account has:

| The account's sudo                                                      | Root steps are run by                                                                                                      |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Needs no password (machines added over root SSH), or the server is root | The server (`POST /v1/desktop/packages`, `POST /v1/desktop/replace-old`), with `sudo -n`                                   |
| Asks for a password                                                     | The command, with `sudo` in your terminal, where you type the password. Without a terminal it prints the commands instead. |
| None                                                                    | Nobody: the command prints the commands for an administrator and stops. Run by root, the command runs them itself.         |

What is installed, and how each package manager's lock is waited for (up to ten minutes; a freshly added machine is often busy with its own updates):

| System                                   | Packages                                                                                                                                                                                    | Waiting for the lock                                                                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Debian, Ubuntu and their relatives (apt) | `tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip python3 fonts-dejavu-core adwaita-icon-theme`, without recommended packages                                 | `apt-get update` is retried while its lists lock is held; the install waits with `DPkg::Lock::Timeout`.                                                                                                                                                                                                                                                              |
| Fedora (dnf)                             | `tigervnc-server-minimal xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal xfconf dbus-daemon xclip python3 dejavu-sans-fonts adwaita-icon-theme`, without weak deps  | dnf waits for another dnf by itself. When something else holds the rpm lock, dnf fails at once and says so only in `/var/log/dnf5.log`; the install is retried while that log names the lock.                                                                                                                                                                        |
| Arch and its relatives (pacman)          | `tigervnc xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal xfconf dbus xclip python ttf-dejavu adwaita-icon-theme`, only what is missing (`--needed`)                | pacman never waits; the install is retried while `/var/lib/pacman/db.lck` exists and a pacman is running. A lock nobody holds stops setup at once with the hint to remove it.                                                                                                                                                                                        |
| openSUSE Leap and Tumbleweed (zypper)    | `xorg-x11-Xvnc xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal xfconf dbus-1 dbus-1-daemon xclip python3 dejavu-fonts adwaita-icon-theme`, without recommended ones | zypper waits with `ZYPP_LOCK_TIMEOUT`. Its "installed, but" exit codes (reboot or restart suggested, a package script failed) count as installed. "A repository was skipped" (106) counts as installed only when all six programs are there afterwards; otherwise the step fails with zypper's output and a last line that says a repository could not be refreshed. |

Choices made per system:

- **Fedora and the systems on Fedora's repositories.** dnf is used where `ID` or `ID_LIKE` names fedora (Fedora, Fedora Asahi Remix, Ultramarine and the like), unless either also names rhel or centos, or the system is Oracle Linux (`ol`) or Amazon Linux (`amzn`): those call themselves Fedora-like too, but their own repositories have no Xfce (it comes from EPEL), so they get the "install these yourself" message. SUSE Linux Enterprise is left out the same way.
- **Arch: no refresh of the package lists.** `pacman -Sy <package>` is the partial upgrade Arch tells people not to do, so setup installs from the lists the machine has and only downloads them when there are none (a fresh image). When the lists are too old for the mirrors, pacman fails with "not found" and setup adds the hint to run `pacman -Syu` first.
- **openSUSE: the stock Xfce panel.** The distribution's own panel setup names three plugins (sound, power, notifications) that an install without recommended packages doesn't bring, and Xfce opens an error box for each. Setup installs `xfce4-panel-branding-upstream` instead, unless the machine already has the openSUSE one. `dbus-run-session` is in `dbus-1` on Leap 15 and in `dbus-1-daemon` after it, so both are named and zypper skips the one a release doesn't have (`--ignore-unknown`).
- **No PolicyKit agent in the desktop.** Fedora's Xfce session starts one (`xfce-polkit`), and it opens an error box in a desktop that is no login session. The runner puts a folder of its own ahead of the system's in `XDG_CONFIG_DIRS` that hides that autostart entry for this desktop only; nothing in the account's own config is touched. The folder is next to the socket, made fresh at every start (anything already at that path is removed first, and the runner goes without the folder when it can't make its own) and removed when the desktop stops.

A root step the server runs has twenty minutes. It runs under `timeout`, as root, which stops the whole step when the time is up: the shell around the package manager, the package manager itself and anything it started. (The server's own account couldn't stop them; they belong to root.) Steps the command runs in a terminal have no time limit; Ctrl-C stops them.

When another Codevisor server on the account owns the desktop unit and this server's desktop runs as a process, `status` says it won't come back by itself once it stops, because the server doesn't start a desktop beside another server's unit (both would use the same socket). If that desktop is alive but not shared, `status` gives its own reason, and setup refuses to start it again and says to remove it.

**The command never runs anything the server tells it to.** The root commands (the package manager's, and removing the old desktop's unit) are built by the command from the machine's own files, with the same code the server uses. The server's answer only says whether a step is needed and who should run it. That matters because the command may be run with sudo while the answer comes from a local port: the server's account, or anyone who binds the port while the server is stopped, must not be able to choose what root runs. Text from the answer is cleaned of control characters before it is printed, every further line of a multi-line text is marked with `|` so it can't pass for the command's own lines, program names are matched against the known list, and the account name must look like one.

The desktop is a separate service from the server, so restarting or updating the server leaves it running. `codevisor-desktop.service` runs `codevisor desktop run`, which writes the X11 cookie, starts Xvnc on the private socket with no TCP port, checks twice that the process holding the desktop's socket listens on no TCP port (whatever else on the machine listens on port 5900 + display doesn't matter), starts an Xfce session, and stops everything if either part exits, so systemd restarts both. The unit names the server's own program files; when those have moved (a self-update into a new folder), the server whose data folder the unit names rewrites it when it starts, and so does a setup that finds the desktop running, without restarting the desktop. It starts at boot when the account lingers (`loginctl enable-linger`), which the installer turns on when it is run as root; `status` says when it isn't.

Which way the desktop runs depends on how the server was installed:

| The server runs as                                                                                                                                           | The desktop runs as                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| A systemd user unit (the installer, run as root or by the account itself)                                                                                    | `codevisor-desktop.service` of that account. Survives server restarts and updates.                                                                   |
| A systemd system unit with `User=`, or anything else without `XDG_RUNTIME_DIR` (cron, nohup), while the account's systemd is up (it lingers or is logged in) | The same user unit: the server reaches the account's systemd through `/run/user/<uid>`.                                                              |
| The same, but the account's systemd isn't up                                                                                                                 | A plain process the server starts and restarts with itself. It stops when the server's unit stops. `status` says it doesn't start by itself at boot. |
| A machine without systemd (containers, `codevisor start` with a pid file)                                                                                    | A plain process, as above.                                                                                                                           |

When a desktop was set up as a plain process and the server later reaches systemd, the server starts it under the user unit at its next start and records that in the config. A plain-process desktop whose runner was killed leaves its X server behind; the server stops that orphan before it starts the desktop again.

When a desktop is set up or removed, the server publishes `server.features.updated`, and connected apps read the machine's features again, so the Desktop appears or goes at once. Removing a desktop, or anything that makes its socket stop being private, also disconnects viewers that are connected: the server looks at each live relay every few seconds, and right away on a removal, and closes it with the reason.

Not done yet: removing the packages again (`remove` leaves them installed).

### What the server shares

A Linux machine shares a desktop when its data folder holds `screen-sharing.json`:

```json
{
  "vnc": {
    "socket": "/run/user/1000/codevisor-desktop.sock",
    "display": 1,
    "xauthority": "/run/user/1000/codevisor-desktop.xauth",
    "name": "Desktop",
    "desktop": "xfce",
    "defaultSize": "1440x900"
  }
}
```

- `socket` is the Unix socket the desktop's VNC server listens on. It is the only required field.
- `display` and `xauthority` are the desktop's X11 display number and cookie file. With `desktop: "xfce"` and a `display`, the server offers 2× scaling and the rich clipboard, both of which reach into the X11 session.
- `name` and `defaultSize` are what viewers see before they connect.

The server reads the file on every request, so a desktop is offered or withdrawn without a restart: `/v1/info` lists `screen-sharing-v1` only while the file names a desktop. A viewer that is already connected is disconnected within a few seconds, with the reason, when the file is removed or the socket stops being private.

A config from an older Codevisor names a TCP `port` and no `socket`. Any account on the machine can dial a local port, so the server never connects to it. The desktop stays listed, viewers are told "This machine's desktop was set up for an older version of Codevisor. Set it up again to share it.", and the server logs one line each time it starts seeing such a config. A `vnc` section that names neither a usable socket (an absolute path) nor only a port is not offered at all, and is logged the same way. Only `screen-sharing-v1` is listed for it; `computer-use-stream-v1` needs a desktop that can be relayed.

Before each connection the server checks that the socket is private to its own account (`src/routes/private-socket.ts`): it must be a socket, owned by the account the server runs as, with no access for group or others. Every folder above it, up to the root, must belong to that account or to root, and must either be closed to writes by group and others or be sticky like `/tmp`, so that no other account can swap the socket or a folder on the way to it. The server resolves links in the folder path first and connects to the path it checked. Otherwise nothing is relayed and the viewer is told which of three things is wrong:

| What the server finds                                                                                      | The viewer is told                                                                                   |
| ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Nothing at the path                                                                                        | The desktop on this machine isn't running.                                                           |
| Something that isn't a socket, a socket owned by another account, or a path the server is denied access to | The desktop on this machine isn't run by the account Codevisor runs as, so Codevisor won't share it. |
| A socket, or a folder above it, that other accounts can open or change                                     | Other accounts on this machine can reach its desktop, so Codevisor won't share it.                   |

When a desktop isn't shared for one of these reasons, the server log names the path and what is wrong with it, for example `[desktop] not shared: /home/dev/.codevisor can be changed by other accounts (mode 775, belongs to uid 1000)`. It is logged when the reason changes, not on every request.

The folder rule is strict on purpose, and it bites where each account has its own group and a umask of 002 (Ubuntu, and Fedora or RHEL with that umask): folders made there are mode 775, so a socket below one is refused even though the group has one member. The rule isn't loosened for that. A desktop that `codevisor desktop setup` starts has its socket either in the account's runtime folder (`/run/user/<uid>`, which systemd makes 700) or, when the server can't see that folder in its environment, in `~/.codevisor/run`; in the second case the server makes `run` mode 700 and takes group and other write access off `~/.codevisor`, its own folder, before it starts the desktop. Folders that aren't Codevisor's (a home folder others can write to) are left as they are and still refused, and the log names the folder. For a hand-made config, put the socket under the runtime folder or make the folder 755.

A socket file left behind by a VNC server that was killed still passes the check, so the viewer is offered the desktop and its connection then closes.

The dev container's desktop (`scripts/dev-container-desktop.sh`) is set up this way: Xvnc listens on a socket in the container's runtime folder with no TCP port, and X11 itself needs the cookie. The script writes the config last. If it stops anywhere before that, for any reason (the cookie can't be written, Xvnc or D-Bus doesn't start, `ss` shows the desktop's TCP port open on any address in either of two checks a second apart, `ss` can't answer, the config can't be written), an exit trap stops Xvnc and D-Bus and removes the socket, the cookie and the config.
