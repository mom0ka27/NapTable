"""Shared plumbing for the HTTP-level server tests."""
import http.client, json, socketserver
from http.server import ThreadingHTTPServer


class FastServer(ThreadingHTTPServer):
    """`HTTPServer.server_bind` resolves the host's FQDN, which blocks for the
    DNS timeout on a machine without a resolver. The value only ever reaches
    the `Server:` header."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.socket.getsockname()[:2]


class JSONClientMixin:
    """`http.client` rather than `urlopen`: the latter re-reads the system
    proxy configuration on every call, which costs seconds per request."""

    def req(self, method, path, value=None, headers=None, expect=200):
        data = None if value is None else json.dumps(value).encode()
        head = {"Content-Type": "application/json"}
        head.update(headers or {})
        connection = http.client.HTTPConnection("127.0.0.1", self.http.server_port, timeout=5)
        try:
            connection.request(method, path, body=data, headers=head)
            response = connection.getresponse()
            raw = response.read()
            body = json.loads(raw) if raw else {}
            self.assertEqual(response.status, expect, body)
            return body
        finally:
            connection.close()
