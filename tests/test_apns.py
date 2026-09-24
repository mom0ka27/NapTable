"""Checks for the hand written ES256, HPACK and HTTP/2 pieces of `server.apns`.

The cryptography is pinned to the RFC 6979 known answer vector, and the frame
layer runs against a fake APNs that speaks real HTTP/2 over a plain socket.
"""
import base64, json, select, socket, struct, threading, time, unittest
from unittest.mock import patch

from server import apns

# RFC 6979 A.2.5: P-256, SHA-256, message "sample".
VECTOR_KEY = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
VECTOR_R = "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716"
VECTOR_S = "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8"
VECTOR_QX = 0x60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6


def _der(tag, payload):
    if len(payload) < 0x80:
        return bytes([tag, len(payload)]) + payload
    length = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
    return bytes([tag, 0x80 | len(length)]) + length + payload


def pkcs8_pem(scalar):
    """Build the `.p8` Apple hands out, so the parser is tested on real DER."""
    ec_key = _der(0x30, _der(0x02, b"\x01") + _der(0x04, scalar.to_bytes(32, "big")))
    algorithm = _der(0x30, bytes.fromhex("06072A8648CE3D0201") + bytes.fromhex("06082A8648CE3D030107"))
    der = _der(0x30, _der(0x02, b"\x00") + algorithm + _der(0x04, ec_key))
    body = base64.b64encode(der).decode()
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END PRIVATE KEY-----\n"


class SignatureTests(unittest.TestCase):
    def test_matches_rfc6979_vector(self):
        key = apns.ES256Key(VECTOR_KEY)
        signature = key.sign(b"sample")
        self.assertEqual(signature[:32].hex().upper(), VECTOR_R)
        self.assertEqual(signature[32:].hex().upper(), VECTOR_S)
        self.assertEqual(key.public_point()[0], VECTOR_QX)

    def test_signature_verifies_and_rejects_tampering(self):
        key = apns.ES256Key(VECTOR_KEY)
        signature = key.sign(b"naptable")
        self.assertTrue(apns.verify_es256(key.public_point(), b"naptable", signature))
        self.assertFalse(apns.verify_es256(key.public_point(), b"naptabl3", signature))

    def test_parses_pkcs8_and_sec1_keys(self):
        self.assertEqual(apns.ES256Key.from_pem(pkcs8_pem(VECTOR_KEY)).d, VECTOR_KEY)
        ec_key = _der(0x30, _der(0x02, b"\x01") + _der(0x04, VECTOR_KEY.to_bytes(32, "big")))
        body = base64.b64encode(ec_key).decode()
        pem = "-----BEGIN EC PRIVATE KEY-----\n" + body + "\n-----END EC PRIVATE KEY-----\n"
        self.assertEqual(apns.ES256Key.from_pem(pem).d, VECTOR_KEY)

    def test_rejects_garbage(self):
        with self.assertRaises(apns.APNsError):
            apns.ES256Key.from_pem("not a key")

    def test_provider_token_is_a_verifiable_jwt(self):
        key = apns.ES256Key(VECTOR_KEY)
        token = apns.provider_token(key, "KEYID12345", "TEAMID6789", 1_700_000_000)
        header, claims, signature = token.split(".")
        pad = lambda part: part + "=" * (-len(part) % 4)
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(header))), {"alg": "ES256", "kid": "KEYID12345"})
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(claims))),
                         {"iss": "TEAMID6789", "iat": 1_700_000_000})
        self.assertTrue(apns.verify_es256(key.public_point(), f"{header}.{claims}".encode(),
                                          base64.urlsafe_b64decode(pad(signature))))


class HPACKTests(unittest.TestCase):
    def test_integer_round_trip_across_the_prefix_boundary(self):
        for value in (0, 1, 14, 15, 16, 127, 128, 255, 1337, 100000):
            for prefix in (4, 5, 6, 7):
                encoded = apns._encode_integer(value, prefix, 0)
                decoded, offset = apns._decode_integer(encoded, 0, prefix)
                self.assertEqual((decoded, offset), (value, len(encoded)), (value, prefix))

    def test_headers_encode_as_literals_without_indexing(self):
        block = apns.encode_headers([("apns-topic", "a.b.push-type.liveactivity"), ("apns-priority", 10)])
        self.assertEqual(block[0], 0x00)
        self.assertIn(b"apns-topic", block)
        self.assertIn(b"10", block)

    def test_status_from_indexed_literal_and_huffman_blocks(self):
        self.assertEqual(apns.status_from_header_block(b"\x88"), 200)
        self.assertEqual(apns.status_from_header_block(b"\x8c"), 400)
        self.assertEqual(apns.status_from_header_block(bytes([0x48, 3]) + b"503"), 503)
        self.assertEqual(apns.status_from_header_block(huffman_status("410")), 410)
        self.assertEqual(apns.status_from_header_block(huffman_status("429")), 429)
        # A dynamic table size update in front of the field is skipped.
        self.assertEqual(apns.status_from_header_block(b"\x3f\xe1\x1f\x88"), 200)

    def test_status_is_none_when_the_block_cannot_be_read(self):
        self.assertIsNone(apns.status_from_header_block(b""))
        self.assertIsNone(apns.status_from_header_block(b"\x82"))  # :method GET, not a response


_HUFFMAN = {"0": (0x00, 5), "1": (0x01, 5), "2": (0x02, 5), "3": (0x17, 6), "4": (0x18, 6),
            "5": (0x19, 6), "6": (0x1A, 6), "7": (0x1B, 6), "8": (0x1C, 6), "9": (0x1D, 6)}


def huffman_status(text):
    bits = "".join(format(_HUFFMAN[c][0], "0%db" % _HUFFMAN[c][1]) for c in text)
    bits += "1" * (-len(bits) % 8)
    data = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
    return bytes([0x48, 0x80 | len(data)]) + data


class _PlainSocket:
    """A socket that answers `selected_alpn_protocol`, so the frame layer can
    be exercised without standing up a TLS certificate."""

    def __init__(self, sock):
        self._sock = sock

    def selected_alpn_protocol(self):
        return "h2"

    def __getattr__(self, name):
        return getattr(self._sock, name)


class _PlainContext:
    def wrap_socket(self, sock, server_hostname=None):
        return _PlainSocket(sock)


class FakeAPNs(threading.Thread):
    """Speaks just enough HTTP/2 to answer one request per connection."""

    def __init__(self, status=200, body=b"", send_settings=True, goaway=False):
        super().__init__(daemon=True)
        self.goaway = goaway
        self.status = status
        self.body = body
        self.send_settings = send_settings
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.port = self.listener.getsockname()[1]
        self.requests = []
        self._stop = threading.Event()

    def run(self):
        while not self._stop.is_set():
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def close(self):
        self._stop.set()
        self.listener.close()

    def _read(self, sock, count):
        chunks = []
        while count:
            chunk = sock.recv(count)
            if not chunk:
                raise ConnectionError("client went away")
            chunks.append(chunk)
            count -= len(chunk)
        return b"".join(chunks)

    def _frame(self, sock):
        header = self._read(sock, 9)
        length = int.from_bytes(header[:3], "big")
        return header[3], header[4], int.from_bytes(header[5:9], "big"), self._read(sock, length) if length else b""

    def _serve(self, sock):
        try:
            self._read(sock, len(apns._PREFACE))
            if self.send_settings:
                sock.sendall(apns._frame(apns._SETTINGS, 0, 0, struct.pack(">HI", 0x5, 16384)))
            headers, body, stream = {}, b"", 1
            settings_acked = not self.send_settings
            while True:
                kind, flags, stream_id, payload = self._frame(sock)
                if kind == apns._SETTINGS and not flags & 0x1:
                    sock.sendall(apns._frame(apns._SETTINGS, 0x1, 0))
                elif kind == apns._SETTINGS and flags & 0x1:
                    settings_acked = True
                elif kind == apns._HEADERS:
                    stream = stream_id
                    headers = decode_literal_headers(payload)
                elif kind == apns._DATA:
                    body += payload
                    if flags & 0x1:
                        break
            # Drain the ACK before closing the socket. Closing with unread
            # bytes sends RST and can erase an otherwise valid rejection.
            while not settings_acked:
                kind, flags, _, _ = self._frame(sock)
                settings_acked = kind == apns._SETTINGS and bool(flags & 0x1)
            self.requests.append({"headers": headers, "body": body})
            if self.goaway:
                # Shutting down: last processed stream 0, so this one never ran.
                sock.sendall(apns._frame(apns._GOAWAY, 0, 0, struct.pack(">II", 0, 0)))
                return
            block = bytes([0x48, len(str(self.status))]) + str(self.status).encode()
            end = 0x4 | (0x1 if not self.body else 0)
            sock.sendall(apns._frame(apns._HEADERS, end, stream, block))
            if self.body:
                sock.sendall(apns._frame(apns._DATA, 0x1, stream, self.body))
        except (ConnectionError, OSError):
            pass
        finally:
            sock.close()


def decode_literal_headers(block):
    """Mirror of `apns.encode_headers`, used by the fake server."""
    headers, offset = {}, 0
    while offset < len(block):
        assert block[offset] == 0x00, "expected a literal without indexing"
        offset += 1
        length, offset = apns._decode_integer(block, offset, 7)
        name = block[offset:offset + length].decode()
        offset += length
        length, offset = apns._decode_integer(block, offset, 7)
        headers[name] = block[offset:offset + length].decode()
        offset += length
    return headers


class MultiplexAPNs(FakeAPNs):
    """Keeps the connection open, allows `max_streams` concurrent streams and
    answers each full batch in reverse order, like APNs answering whichever
    stream finishes first. With `goaway_after_first`, the first connection
    answers its first stream and then shuts down past it."""

    def __init__(self, max_streams, goaway_after_first=False):
        super().__init__()
        self.max_streams = max_streams
        self.goaway_after_first = goaway_after_first
        self.connections = 0
        self.widest = 0

    def _serve(self, sock):
        self.connections += 1
        first_connection = self.connections == 1
        try:
            self._read(sock, len(apns._PREFACE))
            sock.sendall(apns._frame(apns._SETTINGS, 0, 0, struct.pack(">HI", 0x3, self.max_streams)))
            ready = []
            while True:
                kind, flags, stream_id, payload = self._frame(sock)
                if kind == apns._SETTINGS and not flags & 0x1:
                    sock.sendall(apns._frame(apns._SETTINGS, 0x1, 0))
                elif kind == apns._HEADERS:
                    self.requests.append({"headers": decode_literal_headers(payload), "stream": stream_id})
                elif kind == apns._DATA and flags & 0x1:
                    ready.append(stream_id)
                    self.widest = max(self.widest, len(ready))
                    # Answer a full batch, or a short one once the client stops sending.
                    if len(ready) < self.max_streams and select.select([sock], [], [], 0.1)[0]:
                        continue
                    if self.goaway_after_first and first_connection:
                        self._answer(sock, ready[0])
                        sock.sendall(apns._frame(apns._GOAWAY, 0, 0, struct.pack(">II", ready[0], 0)))
                        # Close gracefully: unread bytes would turn close() into a
                        # TCP reset that can discard the GOAWAY before it is read.
                        sock.settimeout(1)
                        while sock.recv(4096):
                            pass
                        return
                    for stream in reversed(ready):
                        self._answer(sock, stream)
                    ready = []
        except (ConnectionError, OSError):
            pass
        finally:
            sock.close()

    def _answer(self, sock, stream):
        sock.sendall(apns._frame(apns._HEADERS, 0x4, stream, bytes([0x48, 3]) + b"200"))
        sock.sendall(apns._frame(apns._DATA, 0x1, stream, json.dumps({"stream": stream}).encode()))


class HTTP2Tests(unittest.TestCase):
    def _client(self, server):
        key = apns.ES256Key(VECTOR_KEY)
        return apns.APNsClient(key, "KEYID", "TEAMID", "me.mom0ka27.naptable",
                               port=server.port, hosts={"production": "127.0.0.1", "sandbox": "127.0.0.1"},
                               channel_hosts={"production": "127.0.0.1", "sandbox": "127.0.0.1"},
                               channel_ports={"production": server.port, "sandbox": server.port})

    def _patched(self, client):
        original = apns.HTTP2Connection.connect

        def connect(self):
            self._context = _PlainContext()
            return original(self)

        apns.HTTP2Connection.connect = connect
        self.addCleanup(setattr, apns.HTTP2Connection, "connect", original)
        return client

    def test_successful_push_sends_the_expected_request(self):
        server = FakeAPNs(status=200)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        result = client.push("a1b2c3", {"aps": {"event": "start"}}, environment="production",
                             expiration=1_700_000_000, collapse_id="abc-start")
        client.close()
        self.assertEqual(result, {"ok": True, "status": 200, "reason": "", "certainty": "accepted"})
        request = server.requests[0]
        self.assertEqual(request["headers"][":path"], "/3/device/a1b2c3")
        self.assertEqual(request["headers"][":method"], "POST")
        self.assertEqual(request["headers"]["apns-push-type"], "liveactivity")
        self.assertEqual(request["headers"]["apns-topic"], "me.mom0ka27.naptable.push-type.liveactivity")
        self.assertEqual(request["headers"]["apns-priority"], "10")
        self.assertEqual(request["headers"]["apns-expiration"], "1700000000")
        self.assertEqual(request["headers"]["apns-collapse-id"], "abc-start")
        self.assertTrue(request["headers"]["authorization"].startswith("bearer "))
        self.assertEqual(json.loads(request["body"]), {"aps": {"event": "start"}})

    def test_rejection_reports_the_apns_reason(self):
        server = FakeAPNs(status=400, body=json.dumps({"reason": "BadDeviceToken"}).encode())
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        result = client.push("dead", {"aps": {}})
        client.close()
        self.assertEqual(result, {"ok": False, "status": 400, "reason": "BadDeviceToken", "certainty": "rejected"})

    def test_broadcast_uses_the_apns_broadcast_endpoint_and_channel_header(self):
        server = FakeAPNs(status=200)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        result = client.broadcast(
            "dHN0LXNyY2gtY2hubA==", {"aps": {"event": "update"}},
            environment="production", expiration=0, collapse_id="school-boundary")
        client.close()
        self.assertEqual(result, {"ok": True, "status": 200, "reason": "", "certainty": "accepted"})
        request = server.requests[0]
        self.assertEqual(request["headers"][":path"], "/4/broadcasts/apps/me.mom0ka27.naptable")
        self.assertEqual(request["headers"]["apns-channel-id"], "dHN0LXNyY2gtY2hubA==")
        self.assertEqual(request["headers"]["apns-push-type"], "liveactivity")
        self.assertEqual(request["headers"]["apns-expiration"], "0")
        self.assertNotIn("apns-topic", request["headers"])

    def test_channel_list_uses_the_management_endpoint(self):
        server = FakeAPNs(status=200, body=json.dumps({"channels": ["channel-a"]}).encode())
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.assertEqual(client.list_channels("sandbox"), ["channel-a"])
        client.close()
        request = server.requests[0]
        self.assertEqual(request["headers"][":method"], "GET")
        self.assertEqual(request["headers"][":path"], "/1/apps/me.mom0ka27.naptable/all-channels")
        self.assertEqual(request["body"], b"")

    def test_transport_failure_is_reported_not_raised(self):
        server = FakeAPNs()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.addCleanup(client.close)
        # Closing a listener from another thread need not cancel accept() on Linux.
        with patch.object(apns.socket, "create_connection", side_effect=ConnectionRefusedError("test connection refused")):
            result = client.push("dead", {"aps": {}})
        self.assertFalse(result["ok"])
        self.assertTrue(result["reason"].startswith("TransportError"))

    def test_oversized_payload_is_refused_before_the_network(self):
        server = FakeAPNs()
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        result = client.push("a1", {"aps": {"blob": "x" * 5000}})
        self.assertEqual(result, {"ok": False, "status": 0, "reason": "PayloadTooLarge"})
        self.assertEqual(server.requests, [])

    def test_a_connection_apns_closed_while_idle_is_replaced_before_sending(self):
        # The fake server closes after every response, like APNs dropping an idle connection.
        server = FakeAPNs(status=200)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.addCleanup(client.close)
        self.assertTrue(client.push("a1", {"aps": {}})["ok"])
        time.sleep(0.05)
        second = client.push("a2", {"aps": {}})
        self.assertEqual(second["certainty"], "accepted", second)
        self.assertEqual(len(server.requests), 2)

    def test_long_idle_connection_is_replaced_without_trying_it(self):
        clock = [0.0]
        connection = apns.HTTP2Connection("127.0.0.1", clock=lambda: clock[0])
        connection.sock = object()  # never touched: age alone decides
        clock[0] = apns.IDLE_RECONNECT + 1
        self.assertTrue(connection._stale())

    def test_goaway_before_the_stream_is_not_sent(self):
        server = FakeAPNs(goaway=True)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.addCleanup(client.close)
        result = client.push("a1", {"aps": {"event": "start"}})
        self.assertEqual(result["certainty"], "notSent", result)

    def test_broadcasts_do_not_share_the_device_push_connection(self):
        client = apns.APNsClient(apns.ES256Key(VECTOR_KEY), "k", "t", "bundle")
        self.assertIsNot(client._connection("production"), client._connection("production", purpose="broadcast"))
        self.assertIsNot(client._request_locks["production"], client._broadcast_locks["production"])

    def test_a_batch_shares_one_connection_as_concurrent_streams(self):
        server = MultiplexAPNs(max_streams=2)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.addCleanup(client.close)
        tokens = ["t%d" % n for n in range(5)]
        results = client.push_many([{"device_token": t, "payload": {"aps": {"n": t}}} for t in tokens])
        self.assertEqual([r["certainty"] for r in results], ["accepted"] * 5)
        self.assertEqual(server.connections, 1)
        self.assertEqual(server.widest, 2, "Streams overlap up to the advertised limit, never past it")
        self.assertEqual([r["headers"][":path"] for r in server.requests], ["/3/device/" + t for t in tokens])

    def test_streams_past_a_goaway_are_resent_on_a_new_connection(self):
        server = MultiplexAPNs(max_streams=3, goaway_after_first=True)
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        self.addCleanup(client.close)
        results = client.push_many([{"device_token": t, "payload": {"aps": {}}} for t in ("a", "b", "c")])
        self.assertEqual([r["certainty"] for r in results], ["accepted"] * 3)
        self.assertEqual(server.connections, 2)
        self.assertEqual([r["headers"][":path"] for r in server.requests].count("/3/device/a"), 1, "The answered stream is not sent twice")

    def test_provider_token_is_reused_until_it_ages_out(self):
        clock = [1_700_000_000.0]
        key = apns.ES256Key(VECTOR_KEY)
        client = apns.APNsClient(key, "KEYID", "TEAMID", "bundle", now=lambda: clock[0])
        first = client.authorization()
        self.assertEqual(first, client.authorization())
        clock[0] += apns.TOKEN_LIFETIME + 1
        self.assertNotEqual(first, client.authorization())


class ChannelManagementTests(unittest.TestCase):
    def client_with_calls(self, responses):
        client = object.__new__(apns.APNsClient)
        client._channel_locks = {env: threading.RLock() for env in ("production", "sandbox")}
        calls = []

        def call(method, suffix, environment="production", body=None, channel_id=None):
            calls.append((method, suffix, environment, body, channel_id))
            return responses.pop(0)

        client._channel_call = call
        return client, calls

    def test_create_finds_the_new_channel_from_before_and_after_lists(self):
        client, calls = self.client_with_calls([
            {"channels": ["existing"]}, None, {"channels": ["existing", "created"]},
        ])
        self.assertEqual(client.create_channel("sandbox"), "created")
        self.assertEqual(calls[1], ("POST", "channels", "sandbox", {
            "message-storage-policy": 1, "push-type": "LiveActivity"}, None))

    def test_create_rejects_an_ambiguous_list_diff(self):
        client, _ = self.client_with_calls([{"channels": []}, None, {"channels": ["a", "b"]}])
        with self.assertRaises(apns.APNsError):
            client.create_channel()

    def test_delete_sends_the_channel_header(self):
        client, calls = self.client_with_calls([None])
        client.delete_channel("channel-a", "production")
        self.assertEqual(calls, [("DELETE", "channels", "production", None, "channel-a")])


class EnvironmentTests(unittest.TestCase):
    def test_returns_none_until_every_variable_is_set(self):
        self.assertIsNone(apns.APNsClient.from_environment({}))
        self.assertIsNone(apns.APNsClient.from_environment({"NAPTABLE_APNS_KEY_ID": "A"}))


if __name__ == "__main__":
    unittest.main()

class SubmissionCertaintyTests(unittest.TestCase):
    def client(self, connection):
        client = apns.APNsClient(apns.ES256Key(VECTOR_KEY), 'key', 'team', 'bundle')
        client._connection = lambda *args, **kwargs: connection
        return client

    def test_start_transport_failure_is_not_replayed(self):
        class Connection:
            calls = 0
            def request_many(self, requests):
                self.calls += 1
                return [('lost', 'response lost after send')] * len(requests)
            def close(self): pass
        connection = Connection()
        result = self.client(connection).push('abcd', {'aps': {'event': 'start'}})
        self.assertEqual(connection.calls, 1)
        self.assertEqual(result['certainty'], 'unknown')
        self.assertFalse(result['ok'])

    def test_empty_body_without_status_is_not_success(self):
        class Connection:
            def request_many(self, requests): return [('response', None, b'')] * len(requests)
            def close(self): pass
        result = self.client(Connection()).push('abcd', {'aps': {'event': 'start'}})
        self.assertFalse(result['ok'])
        self.assertEqual(result['certainty'], 'unknown')

    def test_connection_failure_before_request_is_retryable_not_sent(self):
        class Connection:
            calls = 0
            def request_many(self, requests):
                self.calls += 1
                return [('notSent', 'connect failed')] * len(requests)
            def close(self): pass
        connection = Connection()
        result = self.client(connection).push('abcd', {'aps': {'event': 'start'}})
        self.assertEqual(result['certainty'], 'notSent')
        self.assertEqual(connection.calls, 2, 'Certainly unsent requests get one fresh connection')

    def test_batch_keeps_order_and_only_retries_what_was_never_sent(self):
        class Connection:
            batches = []
            def request_many(self, requests):
                self.batches.append([path for _, path, _, _ in requests])
                if len(self.batches) == 1:
                    return [('response', 200, b''), ('notSent', 'GOAWAY'), ('lost', 'reset'),
                            ('response', 400, b'{"reason":"BadDeviceToken"}')]
                return [('response', 200, b'')] * len(requests)
            def close(self): pass
        connection = Connection()
        results = self.client(connection).push_many(
            [{'device_token': token, 'payload': {'aps': {}}} for token in ('a1', 'b2', 'c3', 'd4')]
            + [{'device_token': 'e5', 'payload': {'aps': {'blob': 'x' * 5000}}}])
        self.assertEqual(connection.batches, [['/3/device/a1', '/3/device/b2', '/3/device/c3', '/3/device/d4'], ['/3/device/b2']])
        self.assertEqual([r.get('certainty') for r in results], ['accepted', 'accepted', 'unknown', 'rejected', None])
        self.assertEqual((results[3]['reason'], results[4]['reason']), ('BadDeviceToken', 'PayloadTooLarge'))
