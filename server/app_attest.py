"""App Attest: evidence that a write comes from this app on a genuine Apple
device, not from a script.

The app makes a key in its Secure Enclave, has Apple attest it once
(`register`), then signs each protected write with it (`check`). The key is a
random identifier of the installation, nothing personal; it also names the
publisher for share quotas.

`NAPTABLE_APP_ATTEST` picks the mode. `enforce` (default) refuses a write
whose assertion is forged: a bad signature, a replay, another app's key or a
garbled one. A write with no assertion at all is let through as unattested,
since a simulator or an older app cannot sign; the server limits those by
address instead. A key the server lost (`unknownKey`) or a skewed clock
(`stale`) counts as unattested too, so a genuine device is never locked out.
`log` refuses nothing, `off` skips the check. Outcomes are counted per UTC+8
day and endpoint for the admin.

Assertion headers on a protected write:

- `X-App-Attest-Key`: the key id Apple returned (base64 of SHA-256 of the key)
- `X-App-Attest-Time`: Unix seconds when the app signed
- `X-App-Attest-Assertion`: base64 of the assertion over
  SHA-256("{METHOD}\\n{path}\\n{time}\\n{hex SHA-256 of the body}")
"""
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import hmac
import os
import secrets
import time

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ZONE = timezone(timedelta(hours=8))
MODES = ("off", "log", "enforce")
# https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
APPLE_ROOT = b"""-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
"""
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
ENVIRONMENTS = {b"appattestdevelop": "development", b"appattest" + b"\0" * 7: "production"}
CHALLENGE_TTL = 300
# How far the app's clock may be from ours when it signs a write.
CLOCK_SKEW = 600
# Outcomes `enforce` refuses: only a forger produces these.
FORGED = frozenset(("badSignature", "replayed", "wrongApp", "malformed"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS attest_keys (
 key_id TEXT PRIMARY KEY, public_key BLOB NOT NULL, counter INTEGER NOT NULL,
 environment TEXT NOT NULL, created_at REAL NOT NULL, last_used REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS attest_outcomes (
 day TEXT NOT NULL, endpoint TEXT NOT NULL, outcome TEXT NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(day, endpoint, outcome)
);
"""


class AttestError(ValueError):
    pass


def cbor(data):
    """Decode the CBOR Apple sends: maps, arrays, byte and text strings, integers."""
    value, rest = _cbor(memoryview(data))
    if rest:
        raise AttestError("trailing CBOR data")
    return value


def _cbor(data):
    if not data:
        raise AttestError("truncated CBOR")
    major, info, data = data[0] >> 5, data[0] & 31, data[1:]
    if info < 24:
        length = info
    elif info <= 27:
        size = 1 << (info - 24)
        if len(data) < size:
            raise AttestError("truncated CBOR")
        length, data = int.from_bytes(data[:size], "big"), data[size:]
    else:
        raise AttestError("unsupported CBOR")
    if major == 0:
        return length, data
    if major == 1:
        return -1 - length, data
    if major in (2, 3):
        if len(data) < length:
            raise AttestError("truncated CBOR")
        chunk = bytes(data[:length])
        return (chunk if major == 2 else chunk.decode()), data[length:]
    if major == 4:
        items = []
        for _ in range(length):
            item, data = _cbor(data)
            items.append(item)
        return items, data
    if major == 5:
        items = {}
        for _ in range(length):
            key, data = _cbor(data)
            items[key], data = _cbor(data)
        return items, data
    raise AttestError("unsupported CBOR")


def _der(data, tag):
    """The contents of the DER element `tag` at the start of `data`."""
    if len(data) < 2 or data[0] != tag:
        raise AttestError("unexpected nonce extension")
    length, offset = data[1], 2
    if length & 0x80:
        size = length & 0x7F
        length, offset = int.from_bytes(data[2:2 + size], "big"), 2 + size
    if len(data) < offset + length:
        raise AttestError("truncated nonce extension")
    return data[offset:offset + length]


def _b64(value):
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise AttestError("not base64")


def client_data(method, path, stamp, body):
    """What the app signs for a write: the request, bound to its body and time."""
    return f"{method}\n{path}\n{stamp}\n{hashlib.sha256(body).hexdigest()}".encode()


class AppAttest:
    def __init__(self, db, lock, app_id=lambda: "", now=time.time, root=APPLE_ROOT, mode=None):
        self.db, self.lock, self.now = db, lock, now
        # `TEAMID.bundle.id`, read on use: the admin may configure it later.
        self.app_id = app_id
        self.root = x509.load_pem_x509_certificate(root)
        mode = mode or os.environ.get("NAPTABLE_APP_ATTEST", "enforce")
        self.mode = mode if mode in MODES else "enforce"
        # Challenges are signed, not stored: a flood of them costs nothing.
        self.secret = secrets.token_bytes(32)
        with self.lock:
            self.db.executescript(SCHEMA)
            self.db.commit()

    # MARK: Attestation

    def challenge(self):
        body = f"{int(self.now())}.{secrets.token_hex(8)}"
        mac = hmac.new(self.secret, body.encode(), hashlib.sha256).hexdigest()[:32]
        return {"challenge": f"{body}.{mac}", "expiresIn": CHALLENGE_TTL}

    def _challenge_valid(self, value):
        parts = value.split(".") if isinstance(value, str) else []
        if len(parts) != 3 or not parts[0].isdigit():
            return False
        mac = hmac.new(self.secret, f"{parts[0]}.{parts[1]}".encode(), hashlib.sha256).hexdigest()[:32]
        return hmac.compare_digest(mac, parts[2]) and 0 <= self.now() - int(parts[0]) <= CHALLENGE_TTL

    def register(self, value):
        """Verify Apple's attestation of a new key and keep its public key."""
        if not isinstance(value, dict) or not all(isinstance(value.get(key), str) for key in ("keyId", "attestation", "challenge")):
            raise AttestError("expected keyId, attestation and challenge")
        if not self._challenge_valid(value["challenge"]):
            raise AttestError("challenge expired or invalid")
        app_id = self.app_id()
        if not app_id:
            raise AttestError("App Attest is not configured on the server")
        key_id = _b64(value["keyId"])
        statement = cbor(_b64(value["attestation"]))
        if not isinstance(statement, dict) or statement.get("fmt") != "apple-appattest":
            raise AttestError("not an App Attest attestation")
        chain = (statement.get("attStmt") or {}).get("x5c") or []
        auth = statement.get("authData")
        if len(chain) < 2 or not isinstance(auth, bytes) or len(auth) < 55:
            raise AttestError("incomplete attestation")
        try:
            leaf, intermediate = (x509.load_der_x509_certificate(item) for item in chain[:2])
            leaf.verify_directly_issued_by(intermediate)
            intermediate.verify_directly_issued_by(self.root)
        except (ValueError, TypeError, InvalidSignature):
            raise AttestError("certificate chain is not Apple's")
        moment = datetime.fromtimestamp(self.now(), timezone.utc)
        for cert in (leaf, intermediate):
            if not cert.not_valid_before_utc <= moment <= cert.not_valid_after_utc:
                raise AttestError("certificate expired")
        nonce = hashlib.sha256(auth + hashlib.sha256(value["challenge"].encode()).digest()).digest()
        try:
            extension = leaf.extensions.get_extension_for_oid(NONCE_OID).value.value
        except x509.ExtensionNotFound:
            raise AttestError("no nonce in the certificate")
        if _der(_der(_der(extension, 0x30), 0xA1), 0x04) != nonce:
            raise AttestError("nonce mismatch")
        public = leaf.public_key()
        point = public.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        if hashlib.sha256(point).digest() != key_id:
            raise AttestError("key id mismatch")
        if auth[:32] != hashlib.sha256(app_id.encode()).digest():
            raise AttestError("attested for another app")
        if int.from_bytes(auth[33:37], "big") != 0:
            raise AttestError("counter must start at 0")
        environment = ENVIRONMENTS.get(auth[37:53])
        if environment is None:
            raise AttestError("unknown App Attest environment")
        length = int.from_bytes(auth[53:55], "big")
        if auth[55:55 + length] != key_id:
            raise AttestError("credential id mismatch")
        der = public.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        with self.lock:
            self.db.execute("INSERT INTO attest_keys VALUES(?,?,0,?,?,?) ON CONFLICT(key_id) DO NOTHING",
                            (value["keyId"], der, environment, self.now(), self.now()))
            self.db.commit()
        return {"registered": True, "environment": environment}

    # MARK: Assertions

    def verify(self, headers, method, path, body):
        """The key id that signed this request, or raise AttestError with the
        outcome that is counted ("missing", "unknownKey", …)."""
        key_id, stamp, assertion = (headers.get(name, "") for name in ("X-App-Attest-Key", "X-App-Attest-Time", "X-App-Attest-Assertion"))
        if not key_id and not assertion:
            raise AttestError("missing")
        with self.lock:
            row = self.db.execute("SELECT public_key,counter FROM attest_keys WHERE key_id=?", (key_id,)).fetchone()
        if row is None:
            raise AttestError("unknownKey")
        if not stamp.isdigit() or abs(self.now() - int(stamp)) > CLOCK_SKEW:
            raise AttestError("stale")
        try:
            value = cbor(_b64(assertion))
            signature, auth = value["signature"], value["authenticatorData"]
        except (AttestError, KeyError, TypeError):
            raise AttestError("malformed")
        if not isinstance(auth, bytes) or len(auth) < 37 or not isinstance(signature, bytes):
            raise AttestError("malformed")
        nonce = hashlib.sha256(auth + hashlib.sha256(client_data(method, path, stamp, body)).digest()).digest()
        try:
            serialization.load_der_public_key(bytes(row[0])).verify(signature, nonce, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature:
            raise AttestError("badSignature")
        if auth[:32] != hashlib.sha256(self.app_id().encode()).digest():
            raise AttestError("wrongApp")
        counter = int.from_bytes(auth[33:37], "big")
        with self.lock:
            # Compare and set together: a replayed assertion never counts twice.
            updated = self.db.execute("UPDATE attest_keys SET counter=?,last_used=? WHERE key_id=? AND counter<?",
                                      (counter, self.now(), key_id, counter)).rowcount
            self.db.commit()
        if not updated:
            raise AttestError("replayed")
        return key_id

    def check(self, headers, method, path, body, endpoint):
        """(key id or None, whether to refuse, outcome): counts the outcome.
        None means unattested; only a forged assertion is refused, and only
        in `enforce` mode."""
        if self.mode == "off":
            return None, False, "off"
        try:
            key_id, outcome = self.verify(headers, method, path, body), "valid"
        except AttestError as error:
            key_id, outcome = None, str(error)
        day = datetime.fromtimestamp(self.now(), ZONE).date().isoformat()
        with self.lock:
            self.db.execute("INSERT INTO attest_outcomes VALUES(?,?,?,1) ON CONFLICT(day,endpoint,outcome) DO UPDATE SET count=count+1",
                            (day, endpoint, outcome))
            self.db.commit()
        return key_id, (self.mode == "enforce" and outcome in FORGED), outcome

    def summary(self, days=7):
        """For the admin: the mode, attested keys and each day's outcomes."""
        first = (datetime.fromtimestamp(self.now(), ZONE).date() - timedelta(days=days - 1)).isoformat()
        with self.lock:
            self.db.execute("DELETE FROM attest_outcomes WHERE day<?", ((datetime.fromtimestamp(self.now(), ZONE).date() - timedelta(days=90)).isoformat(),))
            self.db.commit()
            keys = {row[0]: row[1] for row in self.db.execute("SELECT environment,COUNT(*) FROM attest_keys GROUP BY environment")}
            rows = [dict(day=row[0], endpoint=row[1], outcome=row[2], count=row[3]) for row in self.db.execute(
                "SELECT day,endpoint,outcome,count FROM attest_outcomes WHERE day>=? ORDER BY day DESC,endpoint,outcome", (first,))]
        return {"mode": self.mode, "configured": bool(self.app_id()), "keys": keys, "outcomes": rows}
