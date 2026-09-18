"""Checks for the hand written ES256, HPACK and HTTP/2 pieces of `server.apns`.

The cryptography is pinned to the RFC 6979 known answer vector, and the frame
layer runs against a fake APNs that speaks real HTTP/2 over a plain socket.
"""
import base64, json, socket, struct, threading, unittest

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

    def __init__(self, status=200, body=b"", send_settings=True):
        super().__init__(daemon=True)
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
            while True:
                kind, flags, stream_id, payload = self._frame(sock)
                if kind == apns._SETTINGS and not flags & 0x1:
                    sock.sendall(apns._frame(apns._SETTINGS, 0x1, 0))
                elif kind == apns._HEADERS:
                    stream = stream_id
                    headers = decode_literal_headers(payload)
                elif kind == apns._DATA:
                    body += payload
                    if flags & 0x1:
                        break
            self.requests.append({"headers": headers, "body": body})
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


class HTTP2Tests(unittest.TestCase):
    def _client(self, server):
        key = apns.ES256Key(VECTOR_KEY)
        return apns.APNsClient(key, "KEYID", "TEAMID", "me.mom0ka27.naptable",
                               port=server.port, hosts={"production": "127.0.0.1", "sandbox": "127.0.0.1"})

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
        self.assertEqual(result, {"ok": True, "status": 200, "reason": ""})
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
        self.assertEqual(result, {"ok": False, "status": 400, "reason": "BadDeviceToken"})

    def test_transport_failure_is_reported_not_raised(self):
        server = FakeAPNs()
        server.start()
        port = server.port
        server.close()
        client = self._patched(self._client(server))
        result = client.push("dead", {"aps": {}})
        self.assertFalse(result["ok"])
        self.assertTrue(result["reason"].startswith("TransportError"))
        self.assertEqual(port, server.port)

    def test_oversized_payload_is_refused_before_the_network(self):
        server = FakeAPNs()
        server.start()
        self.addCleanup(server.close)
        client = self._patched(self._client(server))
        result = client.push("a1", {"aps": {"blob": "x" * 5000}})
        self.assertEqual(result, {"ok": False, "status": 0, "reason": "PayloadTooLarge"})
        self.assertEqual(server.requests, [])

    def test_provider_token_is_reused_until_it_ages_out(self):
        clock = [1_700_000_000.0]
        key = apns.ES256Key(VECTOR_KEY)
        client = apns.APNsClient(key, "KEYID", "TEAMID", "bundle", now=lambda: clock[0])
        first = client.authorization()
        self.assertEqual(first, client.authorization())
        clock[0] += apns.TOKEN_LIFETIME + 1
        self.assertNotEqual(first, client.authorization())


class EnvironmentTests(unittest.TestCase):
    def test_returns_none_until_every_variable_is_set(self):
        self.assertIsNone(apns.APNsClient.from_environment({}))
        self.assertIsNone(apns.APNsClient.from_environment({"NAPTABLE_APNS_KEY_ID": "A"}))


if __name__ == "__main__":
    unittest.main()
