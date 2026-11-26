# codevisor-server

## Linux desktops

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

The server reads the file on every request, so a desktop is offered or withdrawn without a restart: `/v1/info` lists `screen-sharing-v1` only while the file names a desktop. That holds for new connections only. A viewer that is already connected keeps streaming after the file is removed or the socket's permissions change, until it disconnects.

A config from an older Codevisor names a TCP `port` and no `socket`. Any account on the machine can dial a local port, so the server never connects to it. The desktop stays listed, viewers are told "This machine's desktop was set up for an older version of Codevisor. Set it up again to share it.", and the server logs one line each time it starts seeing such a config. A `vnc` section that names neither a usable socket (an absolute path) nor only a port is not offered at all, and is logged the same way. Only `screen-sharing-v1` is listed for it; `computer-use-stream-v1` needs a desktop that can be relayed.

Before each connection the server checks that the socket is private to its own account (`src/routes/private-socket.ts`): it must be a socket, owned by the account the server runs as, with no access for group or others. Every folder above it, up to the root, must belong to that account or to root, and must either be closed to writes by group and others or be sticky like `/tmp`, so that no other account can swap the socket or a folder on the way to it. The server resolves links in the folder path first and connects to the path it checked. Otherwise nothing is relayed and the viewer is told which of three things is wrong:

| What the server finds                                                                                      | The viewer is told                                                                                   |
| ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Nothing at the path                                                                                        | The desktop on this machine isn't running.                                                           |
| Something that isn't a socket, a socket owned by another account, or a path the server is denied access to | The desktop on this machine isn't run by the account Codevisor runs as, so Codevisor won't share it. |
| A socket, or a folder above it, that other accounts can open or change                                     | Other accounts on this machine can reach its desktop, so Codevisor won't share it.                   |

When a desktop isn't shared for one of these reasons, the server log names the path and what is wrong with it, for example `[desktop] not shared: /home/dev/.codevisor can be changed by other accounts (mode 775, belongs to uid 1000)`. It is logged when the reason changes, not on every request.

The folder rule is strict on purpose, and it bites on distros that give each account its own group and a umask of 002 (Fedora, RHEL): folders created there are mode 775, so a socket below such a folder is refused even though the group has one member. Put the socket under the account's runtime folder (`/run/user/<uid>`, which is 700), or make the folder 755.

A socket file left behind by a VNC server that was killed still passes the check, so the viewer is offered the desktop and its connection then closes.

The dev container's desktop (`scripts/dev-container-desktop.sh`) is set up this way: Xvnc listens on a socket in the container's runtime folder with no TCP port, and X11 itself needs the cookie. The script writes the config last. If it stops anywhere before that, for any reason (the cookie can't be written, Xvnc or D-Bus doesn't start, `ss` shows the desktop's TCP port open on any address in either of two checks a second apart, `ss` can't answer, the config can't be written), an exit trap stops Xvnc and D-Bus and removes the socket, the cookie and the config.
