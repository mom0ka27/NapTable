#!/usr/bin/env python3
"""APNs client for Live Activity pushes. Standard library only.

Apple offers no HTTP/1.1 push endpoint and the standard library ships no HTTP/2
client and no ECDSA, so this module implements exactly the slice both need:

* ES256 (ECDSA over NIST P-256) with an RFC 6979 deterministic nonce, so the
  provider JWT can be signed without `cryptography` and without a source of
  randomness that a test cannot pin down.
* Enough HTTP/2 to send one shape of request -- POST /3/device/<token> with a
  small JSON body -- over a TLS connection that negotiates `h2` via ALPN.

Nothing here is a general purpose HTTP/2 or JOSE implementation; it handles the
frames and header encodings APNs actually uses and raises on the rest.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import select
import socket
import ssl
import struct
import threading
import time

# ---------------------------------------------------------------------------
# NIST P-256
# ---------------------------------------------------------------------------

_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
_GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
_GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5


def _jacobian_double(point):
    x, y, z = point
    if y == 0:
        return (0, 0, 0)
    ysq = (y * y) % _P
    s = (4 * x * ysq) % _P
    # a = -3 lets the slope fold into 3(x - z^2)(x + z^2).
    zsq = (z * z) % _P
    m = (3 * (x - zsq) * (x + zsq)) % _P
    nx = (m * m - 2 * s) % _P
    ny = (m * (s - nx) - 8 * ysq * ysq) % _P
    nz = (2 * y * z) % _P
    return (nx, ny, nz)


def _jacobian_add(p, q):
    if p[1] == 0:
        return q
    if q[1] == 0:
        return p
    x1, y1, z1 = p
    x2, y2, z2 = q
    z1sq = (z1 * z1) % _P
    z2sq = (z2 * z2) % _P
    u1 = (x1 * z2sq) % _P
    u2 = (x2 * z1sq) % _P
    s1 = (y1 * z2sq * z2) % _P
    s2 = (y2 * z1sq * z1) % _P
    if u1 == u2:
        return _jacobian_double(p) if s1 == s2 else (0, 0, 1)
    h = (u2 - u1) % _P
    r = (s2 - s1) % _P
    h2 = (h * h) % _P
    h3 = (h * h2) % _P
    u1h2 = (u1 * h2) % _P
    nx = (r * r - h3 - 2 * u1h2) % _P
    ny = (r * (u1h2 - nx) - s1 * h3) % _P
    nz = (h * z1 * z2) % _P
    return (nx, ny, nz)


def _multiply(point, scalar):
    result = (0, 0, 1)
    addend = point
    while scalar:
        if scalar & 1:
            result = _jacobian_add(result, addend)
        addend = _jacobian_double(addend)
        scalar >>= 1
    return result


def _to_affine(point):
    x, y, z = point
    if z == 0:
        return (0, 0)
    inv = pow(z, _P - 2, _P)
    inv2 = (inv * inv) % _P
    return ((x * inv2) % _P, (y * inv2 * inv) % _P)


# ---------------------------------------------------------------------------
# Key material
# ---------------------------------------------------------------------------


class APNsError(Exception):
    """Configuration or transport error; the request may already be submitted."""


class APNsNotSentError(APNsError):
    """APNs cannot have acted on the request: nothing, or no complete stream,
    was sent, or the server said it stopped before this stream."""


def _der_read(data, offset):
    """Return (tag, contents, next_offset) for the DER element at `offset`."""
    if offset + 2 > len(data):
        raise APNsError("truncated DER")
    tag = data[offset]
    length = data[offset + 1]
    offset += 2
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or offset + count > len(data):
            raise APNsError("unsupported DER length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    end = offset + length
    if end > len(data):
        raise APNsError("truncated DER")
    return tag, data[offset:end], end


def _pem_body(text):
    lines = [line.strip() for line in text.strip().splitlines()]
    if not lines or not lines[0].startswith("-----BEGIN"):
        raise APNsError("not a PEM private key")
    body = "".join(line for line in lines[1:] if not line.startswith("-----"))
    try:
        return base64.b64decode(body)
    except (ValueError, TypeError) as error:
        raise APNsError("invalid PEM base64") from error


class ES256Key:
    """The `.p8` signing key Apple issues for token based APNs auth."""

    def __init__(self, private_scalar):
        if not 1 <= private_scalar < _N:
            raise APNsError("private key out of range")
        self.d = private_scalar

    @classmethod
    def from_pem(cls, text):
        data = _pem_body(text)
        tag, outer, _ = _der_read(data, 0)
        if tag != 0x30:
            raise APNsError("expected a DER sequence")
        tag, first, offset = _der_read(outer, 0)
        if tag != 0x02:
            raise APNsError("expected a version integer")
        version = int.from_bytes(first, "big")
        if version == 1:
            # SEC1 `EC PRIVATE KEY`: version, privateKey OCTET STRING, ...
            tag, key, _ = _der_read(outer, offset)
            if tag != 0x04:
                raise APNsError("expected an EC private key octet string")
            return cls(int.from_bytes(key, "big"))
        # PKCS#8 `PRIVATE KEY`: version, AlgorithmIdentifier, privateKey.
        tag, _algorithm, offset = _der_read(outer, offset)
        if tag != 0x30:
            raise APNsError("expected an algorithm identifier")
        tag, wrapped, _ = _der_read(outer, offset)
        if tag != 0x04:
            raise APNsError("expected a wrapped private key")
        tag, inner, _ = _der_read(wrapped, 0)
        if tag != 0x30:
            raise APNsError("expected an EC private key sequence")
        tag, _version, inner_offset = _der_read(inner, 0)
        tag, key, _ = _der_read(inner, inner_offset)
        if tag != 0x04:
            raise APNsError("expected an EC private key octet string")
        return cls(int.from_bytes(key, "big"))

    @classmethod
    def from_file(cls, path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return cls.from_pem(handle.read())
        except OSError as error:
            raise APNsError(f"cannot read APNs key at {path}: {error}") from error

    def _nonce(self, digest):
        """RFC 6979 deterministic k. Removes the need for a secure RNG and
        makes the signature a known answer a test can pin."""
        holen = 32
        key_bytes = self.d.to_bytes(32, "big")
        # bits2octets: the digest is already 256 bits, so only the reduction
        # modulo n is left.
        reduced = (int.from_bytes(digest, "big") % _N).to_bytes(32, "big")
        seed = key_bytes + reduced
        v = b"\x01" * holen
        k = b"\x00" * holen
        k = hmac.new(k, v + b"\x00" + seed, hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()
        k = hmac.new(k, v + b"\x01" + seed, hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()
        while True:
            v = hmac.new(k, v, hashlib.sha256).digest()
            candidate = int.from_bytes(v, "big")
            if 1 <= candidate < _N:
                return candidate
            k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
            v = hmac.new(k, v, hashlib.sha256).digest()

    def sign(self, message):
        """Return the 64 byte r||s JOSE signature over `message`."""
        digest = hashlib.sha256(message).digest()
        z = int.from_bytes(digest, "big")
        while True:
            k = self._nonce(digest)
            x, _ = _to_affine(_multiply((_GX, _GY, 1), k))
            r = x % _N
            if r == 0:
                continue
            s = (pow(k, _N - 2, _N) * (z + r * self.d)) % _N
            if s == 0:
                continue
            # JWS does not require low-S normalisation, and leaving the value
            # as RFC 6979 produces it keeps the known answer tests meaningful.
            return r.to_bytes(32, "big") + s.to_bytes(32, "big")

    def public_point(self):
        """Affine public key. Only used by the tests to verify a signature."""
        return _to_affine(_multiply((_GX, _GY, 1), self.d))


def verify_es256(public_point, message, signature):
    """Standalone verifier so the signing path can be checked in tests."""
    if len(signature) != 64:
        return False
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    if not (1 <= r < _N and 1 <= s < _N):
        return False
    z = int.from_bytes(hashlib.sha256(message).digest(), "big")
    w = pow(s, _N - 2, _N)
    point = _jacobian_add(
        _multiply((_GX, _GY, 1), (z * w) % _N),
        _multiply((public_point[0], public_point[1], 1), (r * w) % _N),
    )
    x, _ = _to_affine(point)
    return x % _N == r


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def provider_token(key, key_id, team_id, issued_at):
    """The `authorization: bearer` JWT APNs expects for token based auth."""
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": team_id, "iat": int(issued_at)}, separators=(",", ":")).encode())
    signing_input = header + b"." + claims
    return (signing_input + b"." + _b64url(key.sign(signing_input))).decode()


# ---------------------------------------------------------------------------
# HPACK, reduced to what APNs sends and accepts
# ---------------------------------------------------------------------------

# Only the numeric characters can appear in a `:status` value, and that is the
# single header this client needs to read.
_HUFFMAN_DIGITS = {
    (0x00, 5): "0", (0x01, 5): "1", (0x02, 5): "2",
    (0x17, 6): "3", (0x18, 6): "4", (0x19, 6): "5", (0x1A, 6): "6",
    (0x1B, 6): "7", (0x1C, 6): "8", (0x1D, 6): "9",
}
_STATIC_STATUS = {8: 200, 9: 204, 10: 206, 11: 304, 12: 400, 13: 404, 14: 500}


def _encode_integer(value, prefix_bits, first_byte):
    limit = (1 << prefix_bits) - 1
    if value < limit:
        return bytes([first_byte | value])
    out = bytearray([first_byte | limit])
    value -= limit
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _decode_integer(data, offset, prefix_bits):
    limit = (1 << prefix_bits) - 1
    value = data[offset] & limit
    offset += 1
    if value < limit:
        return value, offset
    shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value += (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, offset


def encode_headers(headers):
    """Literal header fields without indexing, never Huffman coded.

    An HPACK encoder is always allowed to do this, and it keeps the dynamic
    table empty so successive requests on one connection stay independent.
    """
    out = bytearray()
    for name, value in headers:
        name = name.lower().encode()
        value = str(value).encode()
        out += _encode_integer(0, 4, 0x00)
        out += _encode_integer(len(name), 7, 0x00) + name
        out += _encode_integer(len(value), 7, 0x00) + value
    return bytes(out)


def _huffman_digits(data):
    """Decode a Huffman coded `:status` value. Only digits are in that
    alphabet, so the full 257 symbol table is not needed."""
    bits = 0
    width = 0
    out = []
    for byte in data:
        bits = (bits << 8) | byte
        width += 8
        while True:
            for length in (5, 6):
                if width < length:
                    continue
                code = (bits >> (width - length)) & ((1 << length) - 1)
                symbol = _HUFFMAN_DIGITS.get((code, length))
                if symbol is not None:
                    out.append(symbol)
                    width -= length
                    bits &= (1 << width) - 1
                    break
            else:
                break  # not enough bits yet, or a symbol outside the alphabet
    # What is left has to be the all-ones padding, never a whole symbol.
    if width >= 8 or (width and bits != (1 << width) - 1):
        return ""
    return "".join(out)


def status_from_header_block(block):
    """Read `:status` out of a response header block, or None if unreadable.

    `:status` is always the first field of a response block, so the dynamic
    table never has to be tracked: the first field is decoded and the rest of
    the block ignored.
    """
    offset = 0
    while offset < len(block) and block[offset] & 0xE0 == 0x20:
        _size, offset = _decode_integer(block, offset, 5)  # dynamic table size update
    if offset >= len(block):
        return None
    first = block[offset]
    if first & 0x80:
        index, _ = _decode_integer(block, offset, 7)
        return _STATIC_STATUS.get(index)
    prefix_bits = 6 if first & 0x40 else 4
    name_index, offset = _decode_integer(block, offset, prefix_bits)
    if name_index == 0:  # literal name: not the pseudo-header we expect first
        return None
    if name_index != 8:  # static index 8 is `:status`
        return None
    huffman = bool(block[offset] & 0x80)
    length, offset = _decode_integer(block, offset, 7)
    raw = block[offset:offset + length]
    text = _huffman_digits(raw) if huffman else raw.decode("ascii", "ignore")
    try:
        return int(text)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Minimal HTTP/2 client
# ---------------------------------------------------------------------------

_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
_DATA, _HEADERS, _RST_STREAM, _SETTINGS, _PING, _GOAWAY, _WINDOW_UPDATE = 0, 1, 3, 4, 6, 7, 8
_FLAG_ACK = 0x01
_FLAG_END_STREAM = 0x01
_FLAG_END_HEADERS = 0x04
_REFUSED_STREAM = 0x7
# APNs closes connections it considers idle. Past this age a connection is
# replaced before use rather than trusted with a request it may never answer.
IDLE_RECONNECT = 10 * 60


def _frame(kind, flags, stream, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


class HTTP2Connection:
    """One TLS + h2 connection; requests go out as concurrent streams."""

    def __init__(self, host, port=443, timeout=10.0, context=None, clock=time.monotonic):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._context = context
        self._clock = clock
        self._last_used = 0.0
        self.sock = None
        self._next_stream = 1
        self._send_window = 65535
        self._max_frame = 16384
        self._max_streams = 1
        self._unacked = 0

    def connect(self):
        context = self._context
        if context is None:
            context = ssl.create_default_context()
            context.set_alpn_protocols(["h2"])
        raw = socket.create_connection((self.host, self.port), timeout=self.timeout)
        try:
            self.sock = context.wrap_socket(raw, server_hostname=self.host)
        except OSError:
            raw.close()
            raise
        protocol = self.sock.selected_alpn_protocol()
        if protocol not in (None, "h2"):
            self.close()
            raise APNsError(f"server negotiated {protocol!r} instead of h2")
        self._next_stream = 1
        self._send_window = 65535
        self._max_frame = 16384
        self._unacked = 0
        # One stream until APNs states its limit: it may start low and raise
        # the limit once the first request has authenticated.
        self._max_streams = 1
        self._last_used = self._clock()
        # `SETTINGS_ENABLE_PUSH = 0`: this client never accepts server pushes.
        self.sock.sendall(_PREFACE + _frame(_SETTINGS, 0, 0, struct.pack(">HI", 0x2, 0)))

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    @property
    def closed(self):
        return self.sock is None

    def _read_exactly(self, count):
        chunks = []
        remaining = count
        while remaining:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise APNsError("connection closed by peer")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_frame(self):
        header = self._read_exactly(9)
        length = int.from_bytes(header[:3], "big")
        kind = header[3]
        flags = header[4]
        stream = int.from_bytes(header[5:9], "big") & 0x7FFFFFFF
        return kind, flags, stream, self._read_exactly(length) if length else b""

    def _control(self, kind, flags, stream, data):
        """Answer the connection-level frames; True when the frame was one."""
        if kind == _SETTINGS and not flags & _FLAG_ACK:
            self._apply_settings(data)
            self.sock.sendall(_frame(_SETTINGS, _FLAG_ACK, 0))
        elif kind == _PING and not flags & _FLAG_ACK:
            self.sock.sendall(_frame(_PING, _FLAG_ACK, 0, data))
        elif kind == _WINDOW_UPDATE and stream == 0:
            self._send_window += int.from_bytes(data[:4], "big") & 0x7FFFFFFF
        else:
            return kind in (_SETTINGS, _PING, _WINDOW_UPDATE)
        return True

    def _stale(self):
        """Whether the idle connection is already dead.

        Reads what APNs sent while nothing was in flight. A GOAWAY or an EOF
        there means a request written now would be lost with no answer, which
        for a start is indistinguishable from a lost response -- so the
        connection is replaced while nothing has been sent yet.
        """
        if self._clock() - self._last_used > IDLE_RECONNECT:
            return True
        self.sock.settimeout(min(self.timeout, 0.5))
        try:
            while getattr(self.sock, "pending", lambda: 0)() or select.select([self.sock], [], [], 0)[0]:
                kind, flags, stream, data = self._read_frame()
                if kind == _GOAWAY:
                    return True
                self._control(kind, flags, stream, data)
        except (APNsError, OSError, ValueError, ssl.SSLError):
            return True
        finally:
            if self.sock is not None:
                self.sock.settimeout(self.timeout)
        return False

    def request(self, method, path, headers, body=b""):
        """Send one request and return `(status, body)`.

        `status` is None when the response headers could not be decoded; the
        caller must treat that response as unknown, never as a success.
        Raises `APNsNotSentError` only when APNs cannot have processed it.
        """
        outcome = self.request_many([(method, path, headers, body)])[0]
        if outcome[0] == "notSent":
            raise APNsNotSentError(outcome[1])
        if outcome[0] == "lost":
            raise APNsError(outcome[1])
        return outcome[1], outcome[2]

    def request_many(self, requests):
        """Send `(method, path, headers, body)` requests as concurrent streams.

        Returns one outcome per request, in order:

        * `("response", status, body)` -- APNs answered; `status` is None
          when the header block could not be read.
        * `("notSent", reason)` -- APNs cannot have acted on it.
        * `("lost", reason)` -- written, but the answer never arrived.

        Never raises. A batch costs about one round trip instead of one per
        request, which is what keeps a bell's worth of pushes on time.
        """
        outcomes = [None] * len(requests)
        if self.sock is not None and self._stale():
            self.close()
        if self.sock is None:
            try:
                self.connect()
            except (APNsError, OSError, ssl.SSLError) as error:
                return [("notSent", str(error))] * len(requests)
        queue = list(range(len(requests)))
        queue.reverse()  # pop() from the end takes requests in order
        flight = {}  # stream id -> [index, status, body]

        def finish(stream):
            index, status, body = flight.pop(stream)
            outcomes[index] = ("response", status, bytes(body))

        def abandon(reason, refused_above=None):
            # Streams APNs said it never reached are safe to send again.
            for stream, (index, _, _) in flight.items():
                safe = refused_above is not None and stream > refused_above
                outcomes[index] = ("notSent" if safe else "lost", reason)
            flight.clear()
            while queue:
                outcomes[queue.pop()] = ("notSent", reason)

        try:
            while queue or flight:
                while queue and len(flight) < self._max_streams:
                    index = queue[-1]
                    method, path, headers, body = requests[index]
                    block = encode_headers(
                        [(":method", method), (":scheme", "https"), (":path", path), (":authority", self.host)]
                        + list(headers)
                    )
                    if len(body) > self._max_frame or len(block) > self._max_frame:
                        outcomes[queue.pop()] = ("notSent", "request larger than the negotiated frame size")
                        continue
                    if len(body) > self._send_window:
                        break  # wait for APNs to open the flow control window
                    queue.pop()
                    stream = self._next_stream
                    self._next_stream += 2
                    packet = _frame(_HEADERS, _FLAG_END_HEADERS, stream, block)
                    packet += _frame(_DATA, _FLAG_END_STREAM, stream, body)
                    try:
                        self.sock.sendall(packet)
                    except (OSError, ssl.SSLError) as error:
                        # END_STREAM is in the last bytes: an incomplete write
                        # leaves a stream APNs never acts on.
                        outcomes[index] = ("notSent", f"request not fully written: {error}")
                        raise
                    self._send_window -= len(body)
                    flight[stream] = [index, None, bytearray()]
                kind, flags, frame_stream, data = self._read_frame()
                if self._control(kind, flags, frame_stream, data):
                    continue
                if kind == _GOAWAY:
                    last = int.from_bytes(data[:4], "big") & 0x7FFFFFFF
                    self.close()
                    abandon("server sent GOAWAY before responding", refused_above=last)
                    break
                entry = flight.get(frame_stream)
                if entry is None:
                    continue
                if kind == _RST_STREAM:
                    code = int.from_bytes(data[:4], "big")
                    flight.pop(frame_stream)
                    outcomes[entry[0]] = ("notSent" if code == _REFUSED_STREAM else "lost",
                                          "stream refused before processing" if code == _REFUSED_STREAM
                                          else f"stream reset with code {code}")
                elif kind == _HEADERS:
                    entry[1] = status_from_header_block(data)
                    if flags & _FLAG_END_STREAM:
                        finish(frame_stream)
                elif kind == _DATA:
                    entry[2] += data
                    self._unacked += len(data)
                    if flags & _FLAG_END_STREAM:
                        finish(frame_stream)
                if self._unacked >= 16384:
                    self.sock.sendall(_frame(_WINDOW_UPDATE, 0, 0, struct.pack(">I", self._unacked)))
                    self._unacked = 0
        except (APNsError, OSError, ValueError, ssl.SSLError) as error:
            self.close()
            abandon(f"{error}" or type(error).__name__)
        if self.sock is not None:
            self._last_used = self._clock()
        return outcomes

    def _apply_settings(self, data):
        for offset in range(0, len(data) - 5, 6):
            key, value = struct.unpack_from(">HI", data, offset)
            if key == 0x3:  # SETTINGS_MAX_CONCURRENT_STREAMS
                self._max_streams = max(1, min(value, 1000))
            elif key == 0x5:  # SETTINGS_MAX_FRAME_SIZE
                self._max_frame = max(16384, min(value, 1 << 24))


# ---------------------------------------------------------------------------
# APNs
# ---------------------------------------------------------------------------

PRODUCTION_HOST = "api.push.apple.com"
SANDBOX_HOST = "api.sandbox.push.apple.com"
CHANNEL_PRODUCTION_HOST = "api-manage-broadcast.push.apple.com"
CHANNEL_SANDBOX_HOST = "api-manage-broadcast.sandbox.push.apple.com"
MAX_PAYLOAD = 4096
# Apple rejects a provider token younger than 20 minutes on refresh and older
# than 60 minutes on use.
TOKEN_LIFETIME = 40 * 60


class APNsClient:
    """Sends Live Activity pushes to one bundle id, on both APNs environments."""

    def __init__(self, key, key_id, team_id, bundle_id, port=443, timeout=10.0,
                 hosts=None, now=time.time, channel_hosts=None, channel_ports=None):
        self.key = key
        self.key_id = key_id
        self.team_id = team_id
        self.bundle_id = bundle_id
        self.port = port
        self.timeout = timeout
        self.hosts = hosts or {"production": PRODUCTION_HOST, "sandbox": SANDBOX_HOST}
        self.channel_hosts = channel_hosts or {
            "production": CHANNEL_PRODUCTION_HOST,
            "sandbox": CHANNEL_SANDBOX_HOST,
        }
        self.channel_ports = channel_ports or {"production": 2196, "sandbox": 2195}
        self.now = now
        self._lock = threading.Lock()
        self._connections = {}
        self._request_locks = {env: threading.RLock() for env in ("production", "sandbox")}
        # Broadcasts get their own connection so a burst of device pushes at a
        # bell cannot hold them past their one-minute window.
        self._broadcast_locks = {env: threading.RLock() for env in ("production", "sandbox")}
        self._channel_locks = {env: threading.RLock() for env in ("production", "sandbox")}
        self._token = None
        self._token_issued = 0.0

    @classmethod
    def from_environment(cls, environ):
        """Build a client from NAPTABLE_APNS_* variables, or None if unset."""
        path = environ.get("NAPTABLE_APNS_KEY_PATH", "").strip()
        key_id = environ.get("NAPTABLE_APNS_KEY_ID", "").strip()
        team_id = environ.get("NAPTABLE_APNS_TEAM_ID", "").strip()
        bundle_id = environ.get("NAPTABLE_APNS_BUNDLE_ID", "").strip()
        if not (path and key_id and team_id and bundle_id):
            return None
        return cls(ES256Key.from_file(path), key_id, team_id, bundle_id)

    def authorization(self):
        with self._lock:
            now = self.now()
            if self._token is None or now - self._token_issued >= TOKEN_LIFETIME:
                self._token = provider_token(self.key, self.key_id, self.team_id, now)
                self._token_issued = now
            return self._token

    def push(self, device_token, payload, environment="production", push_type="liveactivity",
             priority=10, expiration=0, collapse_id=None, topic=None):
        """Deliver one push. Returns `{ok, status, reason}` and never raises for
        an APNs-level rejection -- only for a transport failure."""
        return self.push_many([{"device_token": device_token, "payload": payload, "push_type": push_type,
                                "priority": priority, "expiration": expiration, "collapse_id": collapse_id,
                                "topic": topic}], environment=environment)[0]

    def push_many(self, notifications, environment="production"):
        """Deliver several pushes as concurrent streams on one connection.

        Each notification is a dict with `device_token` and `payload`, plus the
        optional `push` arguments. Returns one result per notification, in order.
        A request APNs certainly never acted on is tried once more on a fresh
        connection; one whose answer was lost is not, since it may be a start.
        """
        results = [None] * len(notifications)
        requests, positions = [], []
        for position, item in enumerate(notifications):
            body = json.dumps(item["payload"], ensure_ascii=False, separators=(",", ":")).encode()
            if len(body) > MAX_PAYLOAD:
                results[position] = {"ok": False, "status": 0, "reason": "PayloadTooLarge"}
                continue
            headers = [
                ("authorization", "bearer " + self.authorization()),
                ("apns-topic", item.get("topic") or f"{self.bundle_id}.push-type.liveactivity"),
                ("apns-push-type", item.get("push_type") or "liveactivity"),
                ("apns-priority", str(item.get("priority") or 10)),
                ("apns-expiration", str(int(item.get("expiration") or 0))),
            ]
            if item.get("collapse_id"):
                headers.append(("apns-collapse-id", item["collapse_id"][:64]))
            requests.append(("POST", "/3/device/" + item["device_token"], headers, body))
            positions.append(position)
        if not requests:
            return results
        with self._request_locks[environment]:
            outcomes = self._send_many(environment, requests)
            retry = [k for k, outcome in enumerate(outcomes) if outcome[0] == "notSent"]
            if retry:
                again = self._send_many(environment, [requests[k] for k in retry], reset=True)
                for k, outcome in zip(retry, again):
                    outcomes[k] = outcome
        for position, outcome in zip(positions, outcomes):
            results[position] = self._result(outcome)
        return results

    def _send_many(self, environment, requests, reset=False, purpose="device"):
        try:
            connection = self._connection(environment, reset=reset, purpose=purpose)
        except (APNsError, OSError, ssl.SSLError) as error:
            return [("notSent", str(error))] * len(requests)
        return connection.request_many(requests)

    @staticmethod
    def _result(outcome):
        if outcome[0] == "notSent":
            return {"ok": False, "status": 0, "reason": f"TransportError: {outcome[1]}", "certainty": "notSent"}
        if outcome[0] == "lost":
            return {"ok": False, "status": 0, "reason": f"TransportError: {outcome[1]}", "certainty": "unknown"}
        _, status, response = outcome
        reason = ""
        if response:
            try:
                reason = json.loads(response.decode("utf-8")).get("reason", "")
            except (ValueError, UnicodeDecodeError, AttributeError):
                reason = response[:200].decode("utf-8", "replace")
        if status is None:
            return {"ok": False, "status": 0, "reason": "MissingHTTPStatus", "certainty": "unknown"}
        return {"ok": status == 200, "status": status, "reason": reason, "certainty": "accepted" if status == 200 else "rejected"}

    def broadcast(self, channel_id, payload, environment="production", priority=10,
                  expiration=0, collapse_id=None, topic=None):
        """Broadcast one Live Activity update to a channel.

        Broadcast requests use APNs' broadcast endpoint rather than the device
        endpoint. The payload must be identical for every activity subscribed
        to the channel; callers should put only a compact boundary signal in
        ``content-state`` and let the widget resolve local timetable data.
        """
        return self.broadcast_many([{"channel_id": channel_id, "payload": payload, "priority": priority,
                                     "expiration": expiration, "collapse_id": collapse_id, "topic": topic}],
                                   environment=environment)[0]

    def broadcast_many(self, broadcasts, environment="production"):
        """Send several channel broadcasts as concurrent streams on the
        broadcast connection. A boundary update or end is safe to repeat, so a
        lost answer is retried once as well as a request never sent."""
        results = [None] * len(broadcasts)
        requests, positions = [], []
        for position, item in enumerate(broadcasts):
            channel_id = str(item.get("channel_id") or "").strip()
            if not channel_id:
                results[position] = {"ok": False, "status": 0, "reason": "MissingChannelID"}
                continue
            body = json.dumps(item["payload"], ensure_ascii=False, separators=(",", ":")).encode()
            if len(body) > MAX_PAYLOAD:
                results[position] = {"ok": False, "status": 0, "reason": "PayloadTooLarge"}
                continue
            headers = [
                ("authorization", "bearer " + self.authorization()),
                ("apns-channel-id", channel_id),
                ("apns-push-type", "liveactivity"),
                ("apns-priority", str(item.get("priority") or 10)),
                ("apns-expiration", str(int(item.get("expiration") or 0))),
            ]
            if item.get("collapse_id"):
                headers.append(("apns-collapse-id", item["collapse_id"][:64]))
            requests.append(("POST", "/4/broadcasts/apps/" + (item.get("topic") or self.bundle_id), headers, body))
            positions.append(position)
        if not requests:
            return results
        with self._broadcast_locks[environment]:
            outcomes = self._send_many(environment, requests, purpose="broadcast")
            retry = [k for k, outcome in enumerate(outcomes) if outcome[0] != "response"]
            if retry:
                again = self._send_many(environment, [requests[k] for k in retry], reset=True, purpose="broadcast")
                for k, outcome in zip(retry, again):
                    outcomes[k] = outcome
        for position, outcome in zip(positions, outcomes):
            results[position] = self._result(outcome)
        return results

    def _channel_call(self, method, suffix, environment="production", body=None, channel_id=None):
        with self._channel_locks[environment]:
            """Call Apple's Broadcast Channel Management API."""
            payload = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
            headers = [
                ("authorization", "bearer " + self.authorization()),
                ("content-type", "application/json"),
            ]
            if channel_id: headers.append(("apns-channel-id", channel_id))
            path = f"/1/apps/{self.bundle_id}/{suffix.lstrip('/')}"
            for attempt in ((0, 1) if method == "GET" else (0,)):
                connection = self._channel_connection(environment, reset=attempt == 1)
                try:
                    status, response = connection.request(method, path, headers, payload)
                    break
                except (APNsError, OSError, ssl.SSLError) as error:
                    connection.close()
                    if attempt or method != "GET": raise APNsError(f"channel transport error: {error}") from error
            if method == "DELETE" and status in (404, 410):
                return None
            if status not in (200, 201, 204):
                reason = ""
                if response:
                    try: reason = json.loads(response.decode()).get("reason", "")
                    except (ValueError, UnicodeDecodeError): reason = response[:200].decode("utf-8", "replace")
                raise APNsError(f"channel API returned {status or 0} {reason}".strip())
            if not response: return None
            try: return json.loads(response.decode())
            except (ValueError, UnicodeDecodeError) as error: raise APNsError("invalid channel API response") from error

    def list_channels(self, environment="production"):
        value = self._channel_call("GET", "all-channels", environment=environment) or {}
        channels = value.get("channels", []) if isinstance(value, dict) else []
        if not isinstance(channels, list): raise APNsError("invalid channel list")
        return [str(channel).strip() for channel in channels if str(channel).strip()]

    def create_channel(self, environment="production"):
        with self._channel_locks[environment]:
            """Create one Live Activity channel and return its APNs channel ID.

            APNs returns the ID in a response header. The minimal HTTP/2 layer only
            decodes status headers, so a before/after list diff obtains the same ID
            without embedding a full HPACK Huffman decoder.
            """
            before = set(self.list_channels(environment))
            failure = None
            try:
                self._channel_call("POST", "channels", environment=environment, body={
                    "message-storage-policy": 1,
                    "push-type": "LiveActivity",
                })
            except APNsError as error:
                # Lost create responses are reconciled by listing, never POST replay.
                failure = error
            after = set(self.list_channels(environment))
            created = sorted(after - before)
            if len(created) != 1: raise APNsError("APNs did not return one new channel") from failure
            return created[0]

    def delete_channel(self, channel_id, environment="production"):
        channel_id = str(channel_id or "").strip()
        if not channel_id: raise APNsError("missing channel ID")
        self._channel_call("DELETE", "channels", environment=environment, channel_id=channel_id)

    def _connection(self, environment, reset=False, purpose="device"):
        host = self.hosts.get(environment) or self.hosts["production"]
        key = (purpose, host)
        with self._lock:
            connection = self._connections.get(key)
            if reset and connection is not None:
                connection.close()
                connection = None
            if connection is None or connection.closed:
                connection = HTTP2Connection(host, self.port, self.timeout)
                self._connections[key] = connection
            return connection

    def _channel_connection(self, environment, reset=False):
        host = self.channel_hosts.get(environment) or self.channel_hosts["production"]
        port = int(self.channel_ports.get(environment) or self.channel_ports["production"])
        key = ("channel", host, port)
        with self._lock:
            connection = self._connections.get(key)
            if reset and connection is not None:
                connection.close()
                connection = None
            if connection is None or connection.closed:
                connection = HTTP2Connection(host, port, self.timeout)
                self._connections[key] = connection
            return connection

    def close(self):
        with self._lock:
            for connection in self._connections.values():
                connection.close()
            self._connections.clear()
