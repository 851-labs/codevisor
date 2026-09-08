# Browser panes

Choose **New Browser** on a workspace's New Tab page on macOS or iOS to open Google. The pane
uses Chromium on macOS and WebKit on iOS, routed through the workspace's machine connection. Navigation and address
controls use native Liquid Glass. On iOS, the controls float above the page at
the bottom, collapse to a hostname pill while scrolling down, and expand when
scrolling up or tapping the address. Tapping the minimal pill expands the controls;
tapping the expanded address starts editing. Editing keeps them expanded above the
keyboard. On macOS, the window toolbar follows the active pane: browser panes show
the address and navigation controls, chats show their title and workspace context,
and other panes show their title. Command-L edits the active browser's address and
Command-R reloads it. Browser rows in the macOS sidebar and cards in the iOS tab
picker show the page's favicon when available. Favicons use the workspace machine's
proxy, including redirects to localhost. On iOS, pulling down from the top
uses the native refresh control, including on short pages. Its indicator ends
when loading completes, fails, or is stopped.
The iOS navigation bar stays fixed with a translucent system material so content
can scroll behind it. Forward appears only when forward history exists. Idle
addresses omit the scheme, `www.`, standard port, path, query, and fragment;
editing reveals the full URL. Other subdomains and development ports remain visible.
Words and phrases entered in the address bar search Google. Website addresses,
IP addresses, and local dev servers such as `localhost:3000` open directly through
the same machine proxy. The iOS keyboard includes a space bar for search queries.

Typography uses system body text (17 pt on iOS, 13 pt on macOS) and supports
Dynamic Type on iOS. At accessibility sizes, controls stack and stay expanded.
WebKit derives the overscroll background from the document canvas. Browser
chrome uses the page's `theme-color`, falling back to that background, to choose
contrasting text and the iOS material's appearance. Both colors update as the
page changes. The Codevisor homepage declares a black canvas and theme color so
its overscroll and browser chrome match the page.

On iOS, native `obscuredContentInsets` describe the fixed topbar and floating
address controls to WebKit. Fixed and sticky page composers stay above those
controls while ordinary content can draw behind the glass. The insets follow
the device safe area, keyboard layout, Dynamic Type, and address bar collapse.
Collapse and expansion interpolate the obscured inset with the same SwiftUI
animation as the glass, so fixed page controls move with the browser controls;
minimum and maximum viewport insets also supply CSS small/large viewport units.
The scroll view uses matching content insets, so its resting scroll bounds agree
with WebKit's viewport. Returning to the top restores the document's initial
spacing beneath fixed website headers, and the last content can clear the bottom
controls. Changing the top inset keeps a resting page anchored at the top.

Browser panes share their last destination and cookies across connected devices.
Address submissions, links, redirects, back/forward, and SPA route changes publish
the resulting URL. Switching away from a pane and returning imports shared cookies
and adopts the latest shared URL. Visible panes keep their current page; app focus
and incoming server updates do not navigate them. A changed cookie jar can reload
an unchanged URL on entry. History, scroll, zoom, focus, and form drafts remain
local. Reload and pull-to-refresh are local actions.

OAuth callback URLs containing code/state or access/ID tokens stay local until
the website navigates to its resulting route. Cookie sync does not transfer an
in-progress OAuth handshake. Finish login on one device, then re-enter the other
pane. POST-only result pages cannot be reproduced by loading their URL elsewhere.

The cookie jar is scoped to the workspace's machine, shared across its browser
panes, and separate from plugin panes. Native cookie observation includes HttpOnly
cookies, expiry, Secure and SameSite attributes, and deletion. New devices import
previously unseen cookies and adopt the server's existing values and deletions.
Per-cookie revisions prevent stale clients from restoring a logged-out session.
localStorage, sessionStorage, IndexedDB, service workers, and device-bound login
credentials remain local; cookie sharing cannot make every authentication scheme
portable between devices.

## Local development

On macOS, `http://localhost:3000` keeps its original URL and origin. Chromium
proxies all loopback ports through the workspace machine. See
[browser-chromium.md](browser-chromium.md) for the macOS engine and Browser Use integration.

On iOS, entering `http://localhost:3000` opens `http://proxy.localhost:3000` on the
workspace's machine. IPv4 and IPv6 loopback inputs have corresponding aliases.
The server resolves these aliases to its own loopback interface. No public DNS,
port exposure, device VPN, or certificate interception is required for HTTP.

WebKit bypasses configured proxies for literal `localhost`, `127.0.0.1`, and
`::1`, even when proxy failover is disabled. The `.localhost` aliases use the
proxy and preserve WebKit's secure-context behavior. The actual page origin
changes to the alias; the address bar shows that origin honestly.

A bundled WebKit extension redirects HTTP(S) loopback subresource requests to the
same aliases before networking. This covers hardcoded API URLs on other ports,
fetch, XMLHttpRequest, and worker fetches without binding those ports on the
client. Redirect rules retain the port, path, query, method, and request body.
The browser waits for rule installation before loading the first webpage.
Top-level navigations use the navigation delegate to avoid a WebKit resource-rule
redirect stall; the replacement request retains the method and form body.

WebKit ignores redirect actions for WebSocket connections. A document-start
adapter maps loopback WebSocket constructor URLs in pages and frames while
retaining the native WebSocket implementation. Native blocking rules prevent
unhandled literal loopback requests from reaching the client. Worker WebSockets
still require alias URLs; literal worker WebSockets are blocked. WebKit can also
reject `0.0.0.0` subrequests as mixed content before redirects run; use localhost
or the alias for those requests.

These are URL redirects, not origin emulation. CORS, CSP, cookie domains, server
host checks, and OAuth redirect allowlists may need to allow the alias origin.
HTTPS dev sites need a certificate trusted by the client for the alias hostname.
Certificate errors are not bypassed. UDP/WebRTC and external-app URL schemes are
outside the supported browser transport; this is not a device-wide VPN.

## Transport

The shared browser controller configures `WKWebsiteDataStore.proxyConfigurations`
with an HTTP CONNECT proxy and direct failover disabled before loading a page.
For a cloud machine, the endpoint is its existing `CloudRelayLoopbackBridge`.
That bridge carries opaque, encrypted, flow-controlled TCP streams to the
Codevisor listener. Direct connections use the machine's existing HTTP(S)
endpoint and transport security.

`POST /v1/browser/proxy-session`, behind normal machine authorization, returns a
separate random browser credential. Website callers with an Origin header are
rejected. The response is not cacheable. Credentials live for the server process;
Retry reacquires them after a restart. Every CONNECT requires proxy authorization,
including connections from loopback. Credentials are consumed at the proxy and
never forwarded to websites.

The server validates CONNECT authorities, rejects its own listener port for all
hostnames, bounds concurrent connections, and closes tunnels at shutdown. It
forwards bytes without changing Host, Origin, website authorization, cookies,
response bodies, TLS, or WebSocket framing.

The browser cookie and navigation routes use the same native machine authorization
and refuse website Origin headers. Per-cookie revisions reject stale overwrites
and retain deletion records. Cookie values stay in the machine's private SQLite
database; they never enter the general workspace event log or pane metadata.

## Verification

Server tests cover authorization, target validation, loopback aliases, control
API protection, connection limits, failures, cleanup, HTTP body/header streaming,
and WebSockets. Native WebKit integration tests cover proxy routing, cross-port
GET and POST, workers, frames, form navigation, and direct-loopback blocking.
Pane tests cover persistence, shared URL activation, cookie-before-navigation
ordering, cookie conflicts, and the absence of visible-pane navigation updates.
