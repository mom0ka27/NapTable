"""Permanent and time-limited Live Activity entitlements.

There are no accounts.  A verified StoreKit transaction is the source of
truth; the transaction is attached to the current Live Activity device so a
restored purchase can be used after moving to another device.
"""
from contextlib import contextmanager
import base64
import hashlib
import json
import time

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

TRIAL_PRODUCT = "com.niyiwei.naptable.live_activity.trial_30d"
LIFETIME_PRODUCT = "com.niyiwei.naptable.live_activity.lifetime"
TRIAL_SECONDS = 30 * 24 * 60 * 60

# Apple Root CA - G3, downloaded from Apple's certificate authority directory.
APPLE_ROOT_CA = b"""-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQQLDB1cHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----
"""

SCHEMA = """
CREATE TABLE IF NOT EXISTS device_entitlements (
 device TEXT NOT NULL,
 transaction_id TEXT NOT NULL,
 original_transaction_id TEXT NOT NULL,
 product TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('trial', 'lifetime')),
 environment TEXT NOT NULL,
 purchased_at REAL NOT NULL,
 expires_at REAL,
 revoked INTEGER NOT NULL DEFAULT 0,
 updated_at REAL NOT NULL,
 PRIMARY KEY(device, transaction_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS device_entitlements_transaction
  ON device_entitlements(transaction_id);
CREATE INDEX IF NOT EXISTS device_entitlements_device
  ON device_entitlements(device, revoked, expires_at);
CREATE TABLE IF NOT EXISTS entitlement_settings (
 key TEXT PRIMARY KEY,
 value TEXT NOT NULL
);
"""

SETTINGS = {"requireEntitlement": True}


class EntitlementError(ValueError):
    pass


def _b64(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _verify_certificate(child, parent):
    try:
        key = parent.public_key()
        if isinstance(key, ec.EllipticCurvePublicKey):
            key.verify(child.signature, child.tbs_certificate_bytes,
                       ec.ECDSA(child.signature_hash_algorithm))
        elif isinstance(key, rsa.RSAPublicKey):
            key.verify(child.signature, child.tbs_certificate_bytes,
                       padding.PKCS1v15(), child.signature_hash_algorithm)
        else:
            raise EntitlementError("unsupported Apple certificate key")
    except InvalidSignature as error:
        raise EntitlementError("invalid Apple certificate chain") from error


def verify_transaction(jws, expected_bundle=None, now=None):
    """Verify an App Store signed transaction and return its payload.

    StoreKit's ES256 JWS carries Apple's certificate chain in ``x5c``.  The
    server verifies the leaf signature and pins the chain to Apple's Root CA;
    merely decoding a client supplied JSON object never grants an entitlement.
    """
    if not isinstance(jws, str) or jws.count(".") != 2:
        raise EntitlementError("invalid signed transaction")
    encoded_header, encoded_payload, encoded_signature = jws.split(".")
    try:
        header = json.loads(_b64(encoded_header))
        payload = json.loads(_b64(encoded_payload))
        signature = _b64(encoded_signature)
        certificates = [x509.load_der_x509_certificate(base64.b64decode(item)) for item in header["x5c"]]
    except (KeyError, ValueError, TypeError, json.JSONDecodeError) as error:
        raise EntitlementError("malformed signed transaction") from error
    if header.get("alg") != "ES256" or len(signature) != 64 or len(certificates) < 2:
        raise EntitlementError("unsupported signed transaction")
    root = x509.load_pem_x509_certificate(APPLE_ROOT_CA)
    for index, certificate in enumerate(certificates[1:], 1):
        _verify_certificate(certificates[index - 1], certificate)
    _verify_certificate(certificates[-1], root)
    try:
        certificates[0].public_key().verify(
            encode_der_signature(signature),
            (encoded_header + "." + encoded_payload).encode(),
            ec.ECDSA(hashes.SHA256()),
        )
    except InvalidSignature as error:
        raise EntitlementError("invalid signed transaction signature") from error
    if expected_bundle and payload.get("bundleId") != expected_bundle:
        raise EntitlementError("transaction Bundle ID mismatch")
    if payload.get("productId") not in (TRIAL_PRODUCT, LIFETIME_PRODUCT):
        raise EntitlementError("unknown entitlement product")
    if not payload.get("transactionId") or not payload.get("originalTransactionId"):
        raise EntitlementError("transaction identifiers missing")
    purchased_ms = payload.get("purchaseDate")
    if type(purchased_ms) not in (int, float) or purchased_ms <= 0:
        raise EntitlementError("transaction purchase date missing")
    if now is not None and purchased_ms / 1000 > now() + 600:
        raise EntitlementError("transaction is from the future")
    if payload.get("revocationDate") is not None:
        payload["revoked"] = True
    return payload


def encode_der_signature(raw):
    """Convert the 64-byte JOSE ECDSA signature to ASN.1 DER."""
    def integer(data):
        data = data.lstrip(b"\0") or b"\0"
        if data[0] & 0x80:
            data = b"\0" + data
        return b"\x02" + bytes([len(data)]) + data
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class Entitlements:
    def __init__(self, db, lock, now=time.time, bundle_id=None):
        self.db, self.lock, self.now, self.bundle_id = db, lock, now, bundle_id
        self.on_change = lambda devices: None
        with self.lock:
            self.db.executescript(SCHEMA)
            self.db.commit()

    @contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield self.db
                self.db.commit()
            except BaseException:
                self.db.rollback()
                raise

    def settings(self):
        with self.lock:
            stored = {row[0]: json.loads(row[1]) for row in self.db.execute("SELECT key,value FROM entitlement_settings")}
        return {**SETTINGS, **{key: value for key, value in stored.items() if key in SETTINGS}}

    def save_settings(self, value):
        if not isinstance(value, dict) or set(value) - set(SETTINGS):
            raise EntitlementError("settings keys are requireEntitlement")
        if "requireEntitlement" in value and type(value["requireEntitlement"]) is not bool:
            raise EntitlementError("requireEntitlement must be true or false")
        before = self.settings()
        with self.transaction() as db:
            for key, item in value.items():
                db.execute("INSERT INTO entitlement_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           (key, json.dumps(item)))
        if value.get("requireEntitlement", before["requireEntitlement"]) != before["requireEntitlement"]:
            self.on_change(None)
        return self.settings()

    def required(self):
        return self.settings()["requireEntitlement"]

    def _active(self, db, device):
        now = self.now()
        return db.execute("""SELECT * FROM device_entitlements
                            WHERE device=? AND revoked=0
                              AND (kind='lifetime' OR expires_at>?)
                            ORDER BY kind='lifetime' DESC, expires_at DESC""", (device, now)).fetchone()

    def allows(self, db, device, day=None):
        return not self.required() or self._active(db, device) is not None

    def entitlement(self, db, device):
        row = self._active(db, device)
        if row is None:
            return {"required": self.required(), "kind": None, "expiresAt": None, "source": None}
        return {"required": self.required(), "kind": row["kind"],
                "expiresAt": row["expires_at"],
                "source": "lifetime" if row["kind"] == "lifetime" else "trial"}

    def grant_transaction(self, db, device, jws):
        payload = verify_transaction(jws, expected_bundle=self.bundle_id, now=self.now)
        product = payload["productId"]
        kind = "trial" if product == TRIAL_PRODUCT else "lifetime"
        purchased_at = payload["purchaseDate"] / 1000
        expires_at = purchased_at + TRIAL_SECONDS if kind == "trial" else None
        revoked = bool(payload.get("revoked"))
        with self.transaction() as tx:
            existing = tx.execute("SELECT * FROM device_entitlements WHERE transaction_id=?", (payload["transactionId"],)).fetchone()
            if existing:
                # The transaction is the Apple ID's identity; a restore may
                # attach it to a new device. Move the single binding instead
                # of inserting a duplicate transaction row.
                tx.execute("""UPDATE device_entitlements SET device=?, product=?, kind=?,
                           environment=?, purchased_at=?, expires_at=?, revoked=?, updated_at=?
                           WHERE transaction_id=?""",
                           (device, product, kind, payload.get("environment", "production"),
                            purchased_at, expires_at, int(revoked), self.now(), payload["transactionId"]))
            else:
                tx.execute("""INSERT INTO device_entitlements
                         (device,transaction_id,original_transaction_id,product,kind,environment,purchased_at,expires_at,revoked,updated_at)
                         VALUES(?,?,?,?,?,?,?,?,?,?)
                         """, (device, payload["transactionId"], payload["originalTransactionId"], product, kind,
                               payload.get("environment", "production"), purchased_at, expires_at, int(revoked), self.now()))
        self.on_change([device])
        return self.entitlement(self.db, device)

    def admin_summary(self):
        with self.lock:
            active = self.db.execute("""SELECT COUNT(DISTINCT device) FROM device_entitlements
                                      WHERE revoked=0 AND (kind='lifetime' OR expires_at>?)""", (self.now(),)).fetchone()[0]
            trials = self.db.execute("SELECT COUNT(DISTINCT device) FROM device_entitlements WHERE kind='trial' AND revoked=0 AND expires_at>?", (self.now(),)).fetchone()[0]
            lifetime = self.db.execute("SELECT COUNT(DISTINCT device) FROM device_entitlements WHERE kind='lifetime' AND revoked=0",).fetchone()[0]
        return {"entitledDevices": active, "trialDevices": trials, "lifetimeDevices": lifetime, "settings": self.settings()}
