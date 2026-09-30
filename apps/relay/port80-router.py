# The only process on the relay's plain-HTTP port (docs/plans/codevisor-tunnel.md).
# /.well-known/acme-challenge/<token> -> file from certbot's webroot (HTTP-01).
# Everything else -> the relay's own HTTP listener (captive-portal checks).
# Standard library only; Python is already in the image for certbot.
import http.client, http.server, os, socket

WEBROOT = os.environ.get("ACME_WEBROOT", "/data/acme-webroot")
UPSTREAM = os.environ.get("RELAY_HTTP_BIND_ADDR", "127.0.0.1:8080")
LISTEN_HOST = os.environ.get("ROUTER_HOST", "::")
LISTEN_PORT = int(os.environ.get("ROUTER_PORT", "80"))
PREFIX = "/.well-known/acme-challenge/"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith(PREFIX):
            token = self.path[len(PREFIX):]
            if not token or "/" in token or token.startswith("."):
                return self.send_error(404)
            try:
                with open(os.path.join(WEBROOT, PREFIX.strip("/"), token), "rb") as f:
                    body = f.read()
            except OSError:
                return self.send_error(404)
            return self.reply(200, [("Content-Type", "text/plain")], body)
        try:
            upstream = http.client.HTTPConnection(UPSTREAM, timeout=5)
            upstream.request("GET", self.path, headers=dict(self.headers))
            r = upstream.getresponse()
            skip = {"connection", "transfer-encoding", "content-length", "server", "date"}
            self.reply(r.status, [(k, v) for k, v in r.getheaders() if k.lower() not in skip], r.read())
        except OSError:
            self.send_error(502)

    def reply(self, status, headers, body):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6 if ":" in LISTEN_HOST else socket.AF_INET


Server((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
