# Codevisor browser panes

macOS browser panes embed Chromium (CEF Alloy) in the native workspace. iOS uses
WKWebView and retains its existing native glass toolbar and scroll behavior.
New panes start at Google; words entered in the address field search Google.

On macOS, right-click a page and choose **Inspect** to reveal that element, or
press **⌥⌘I** to open DevTools. Its **Customize and control DevTools → Dock side**
menu supports a separate window, left, bottom, and right. Right is the default;
the app remembers the selected location. Moving the same frontend between these
locations preserves console history, breakpoints, and the inspected page.
Drag the divider to resize a docked panel. Close it with DevTools' close button
or the separate window's close button. Use **⌘L** to edit the address and **⌘R**
to reload. The address toolbar has no DevTools button.

The docked frontend loads assets from the exact bundled CEF resource pack. Its
renderer receives a private IPC binding and talks to its page through CEF's
DevTools protocol API; no debugging port is opened. It owns a separate protocol
session, which detaches when DevTools closes. Normal page renderers receive no
native DevTools binding. The frontend's resource origin is handled locally only
in its own browser, and frontend navigation is restricted to that origin.

CEF's built-in DevTools popup uses Chrome style, which cannot have a native
parent on macOS. This integration uses the hosted frontend in an Alloy child
view instead. Reference: [CEF source](https://github.com/chromiumembedded/cef/blob/cd89341bfe7eb5e856e98c8cac9b29fe5f77f926/libcef/browser/browser_host_create.cc),
commit `cd89341bfe7eb5e856e98c8cac9b29fe5f77f926`.

## Sessions and navigation

Each client maintains a persistent profile per workspace machine. Cookies sync
through that machine's authenticated server; local storage, IndexedDB, service
workers, and live history stay on the client. macOS CEF profiles are under the
app variant's Application Support directory; iOS uses WKWebsiteDataStore.

The server stores cookie revisions and deletion records in its private database.
Clients exchange per-cookie changes, reject stale overwrites, suppress echoes,
and import cookies before adopting a shared URL. HttpOnly, Secure, SameSite,
expiry, domain, and path are preserved. WebKit loopback aliases map to canonical
localhost identities in the shared jar. Chromium partitioned cookies are excluded
because WebKit's cookie API cannot round-trip their partition key. Cookie sync
cannot transfer logins backed by local storage, device keys, or other browser-only
state, and it does not make an in-progress OAuth handshake portable.

Ordinary navigations, redirects, back/forward and SPA history changes publish the
pane's latest safe URL. Selecting another tab and returning adopts that URL;
app focus and remote updates never navigate a visible pane. A changed cookie jar
can reload the same URL on entry. Common OAuth callback codes, states and tokens
are excluded from saved locations. Complete a fresh login on one device, then
re-enter the other browser pane to adopt the authenticated session.

## Browser Use

Settings offers **Codevisor Extension**, **Chromium**, and **Built-in Browser**.
Existing `chrome` and `managed` preferences retain their meaning. New sessions
default to `builtin`, which uses a browser pane in the same machine's macOS client
when the session's workspace is available. A mode-0600 Unix socket and an
installation-specific token provide access; this endpoint is not served through
HTTP or a cloud relay, and only locally hosted workspace panes are registered.
Automation appends ordinary workspace tabs in the background without changing
the user's selected tab or keyboard focus. Chromium can load and accept commands
before the user opens the pane. Automation attaches its own CDP session,
independent of an open DevTools frontend. It cannot quit the native app.

If that host is unavailable, the server launches independent Chromium with the
shared cookie jar. Linux without DISPLAY or WAYLAND_DISPLAY uses headless mode;
CODEVISOR_BROWSER_HEADLESS explicitly overrides detection. After a native
connection fails, Browser Use reports the interruption, discards old targets and
snapshots, and uses fallback on the next call. It never repeats an uncertain
action automatically or switches the task back when the app returns.

The responsive viewport button exposes width, height, DPR, mobile/touch, presets,
rotation and reset. Browser Use's viewport capability accepts the same settings.
Chromium device emulation is still Chromium, not WebKit.

## Machine routing

macOS configures Chromium's HTTP proxy with the workspace machine's direct or
encrypted cloud-relay endpoint and `bypass_list: "<-loopback>"`. All HTTP, HTTPS,
and WebSocket destinations use the selected machine, including localhost and
loopback IPs at any port. The original address and Origin remain unchanged.
A page at `http://localhost:3000` can fetch `http://localhost:3001` when the API's
normal CORS policy permits that origin. No corresponding client port is bound.

The server accepts absolute-form HTTP and WebSocket requests and CONNECT tunnels
for HTTPS. The native client obtains a proxy capability through its authenticated
machine connection. Only proxy authentication challenges receive that capability;
website requests never receive it. HTTPS is tunneled without TLS interception.
The server rejects proxy requests to its own listener port, including DNS aliases.
Chromium requires the `browser-http-proxy-v1` server feature before it loads a page.

The iOS WebKit route uses `proxy.localhost` (with IPv4/IPv6 variants) and extension network rules
needed for WebKit's loopback-proxy bypass behavior. It therefore retains the
previous limitations for remote localhost origins; adopting Chromium on macOS
does not remove iOS WebKit's restrictions.

## Building and packaging

Use `bun run dev`, `bun run dev:macos`, or `bun run build:macos`. The native runners
prepare the pinned CEF SDK and wrapper automatically. The Xcode build embeds the
framework, helper apps, license, and credits. Renderers use CEF's macOS sandbox
and a JIT entitlement; the app does not disable the Chromium sandbox, TLS, or CORS.

`scripts/chromium-artifact.mjs` pins CEF
`152.0.5+gb129680+chromium-152.0.7977.54`, verifies SDK download checksums, and builds
the wrapper and helper for the requested architecture. The release build prepares
both arm64 and x86_64 and combines their binaries and V8 snapshots. Release signing
seals libraries, helper apps, the framework, and the enclosing app in that order.
Update the pinned artifacts as part of Chromium security maintenance.
