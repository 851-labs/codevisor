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

- `socket` is the Unix socket the desktop's VNC server listens on. It is the only required field. A config that names a TCP port instead is ignored: any account on the machine can dial a local port.
- `display` and `xauthority` are the desktop's X11 display number and cookie file. With `desktop: "xfce"` and a `display`, the server offers 2× scaling and the rich clipboard, both of which reach into the X11 session.
- `name` and `defaultSize` are what viewers see before they connect.

The server reads the file on every request, so a desktop appears or goes away without a restart: `/v1/info` lists `screen-sharing-v1` only while the file names a socket.

Before each connection the server checks that the socket is private to its own account (`src/routes/private-socket.ts`): it must be a socket, owned by the account the server runs as, with no access for group or others. Every folder above it, up to the root, must belong to that account or to root, and must either be closed to writes by group and others or be sticky like `/tmp`, so that no other account can swap the socket or a folder on the way to it. The server resolves links in the folder path first and connects to the path it checked. Otherwise the viewer is told why and nothing is relayed. A socket that isn't there reads as a desktop that isn't running.

The dev container's desktop (`scripts/dev-container-desktop.sh`) is set up this way: Xvnc listens on a socket in the container's runtime folder with no TCP port, X11 itself needs the cookie, and the script refuses to go on if a TCP port is open after all.
