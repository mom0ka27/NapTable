"""Shared plumbing for the HTTP-level server tests."""
import http.client, json, socket, threading, time

import uvicorn

from server.naptable_server import create_app, server_config


class LiveServer:
    """The app on a real uvicorn socket, with the settings `main` uses, but
    without the Live Activity worker threads: tests drive those by hand."""

    def __init__(self, store, live_activity=None, subscriptions=None):
        self.store, self.live_activity = store, live_activity
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("127.0.0.1", 0))
        self.server_port = sock.getsockname()[1]
        self.server = uvicorn.Server(server_config(create_app(store, live_activity, workers=False, subscription_store=subscriptions)))
        self.thread = threading.Thread(target=self.server.run, kwargs={"sockets": [sock]}, daemon=True)
        self.thread.start()
        deadline = time.monotonic() + 5
        while not self.server.started:
            if not self.thread.is_alive() or time.monotonic() > deadline:
                raise RuntimeError("test server did not start")
            time.sleep(0.01)

    def shutdown(self):
        self.server.should_exit = True
        self.thread.join(timeout=5)


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
