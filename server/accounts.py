"""Sign in with Apple accounts and the Live Activity entitlement.

An account is keyed by a hash of the Apple `sub`; no name or email is asked
for. Live Activity reminders need an entitlement once enforcement starts
(`enforceAfter`, a UTC+8 date; empty keeps everything free):

- an App Store subscription, while it runs (rows arrive in phase 2), or
- credit: usage days from the free trial and admin grants. A UTC+8 day costs
  one credit day only when a reminder of that account actually starts on it,
  on any of its devices; days while subscribed cost nothing.

The balance is the sum of `credit_ledger` less the `usage_charges` rows, so
every change is an appended row that can be audited.
"""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from . import apns
except ImportError:  # pragma: no cover - depends on how the server was started
    import apns

ZONE = timezone(timedelta(hours=8))
APPLE_ISSUER = "https://appleid.apple.com"
DEFAULT_BUNDLE_ID = "me.mom0ka27.naptable"
NONCE_TTL = 600
# Sessions slide: one unused this long is gone.
SESSION_TTL = 180 * 86400
# Crockford base32 without look-alikes: what an admin reads out to a user.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
GROUPS = ("all", "trial", "subscribed", "expired")
# The app sends a square photo it already scaled down (256 px); this is a ceiling, not a target.
AVATAR_BYTES = 256 * 1024
AVATAR_TYPES = ((b"\xff\xd8\xff", "image/jpeg"), (b"\x89PNG\r\n\x1a\n", "image/png"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
 id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE, apple_hash TEXT NOT NULL UNIQUE,
 refresh_token TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL, last_seen REAL NOT NULL,
 name TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS account_sessions (
 token_hash TEXT PRIMARY KEY, account TEXT NOT NULL, created_at REAL NOT NULL, last_used REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS account_sessions_account ON account_sessions(account);
CREATE TABLE IF NOT EXISTS account_devices (
 device TEXT PRIMARY KEY, account TEXT NOT NULL, bound_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS account_devices_account ON account_devices(account);
CREATE TABLE IF NOT EXISTS account_nonces (hash TEXT PRIMARY KEY, expires_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS credit_ledger (
 id INTEGER PRIMARY KEY, account TEXT NOT NULL, days INTEGER NOT NULL, reason TEXT NOT NULL,
 note TEXT NOT NULL DEFAULT '', batch TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS credit_ledger_account ON credit_ledger(account);
CREATE TABLE IF NOT EXISTS usage_charges (
 account TEXT NOT NULL, day TEXT NOT NULL, charged_at REAL NOT NULL, PRIMARY KEY(account, day)
);
CREATE TABLE IF NOT EXISTS trial_claims (apple_hash TEXT PRIMARY KEY, claimed_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS subscriptions (
 original_transaction TEXT PRIMARY KEY, account TEXT NOT NULL, product TEXT NOT NULL,
 environment TEXT NOT NULL, expires_at REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS subscriptions_account ON subscriptions(account);
CREATE TABLE IF NOT EXISTS account_avatars (
 account TEXT PRIMARY KEY, version TEXT NOT NULL UNIQUE, mime TEXT NOT NULL, data BLOB NOT NULL, updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS account_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS account_audit (
 id INTEGER PRIMARY KEY, action TEXT NOT NULL, detail TEXT NOT NULL, created_at REAL NOT NULL
);
"""

SETTINGS = {"enforceAfter": "", "trialDays": 30, "bundleID": DEFAULT_BUNDLE_ID,
            "teamID": "", "keyID": "", "keyPath": ""}


class AccountError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _b64decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _day(stamp):
    return datetime.fromtimestamp(stamp, ZONE).date().isoformat()


def _fetch(url, data=None, headers=None, timeout=10):
    """(status, body) of one HTTPS request; Apple's error answers included."""
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class AppleIdentity:
    """Sign in with Apple: identity tokens checked against Apple's published
    keys, and the REST calls that exchange and revoke a user's tokens."""
    def __init__(self, fetch=_fetch, now=time.time):
        self.fetch, self.now = fetch, now
        self._keys, self._loaded = {}, 0

    def _key(self, kid):
        # Apple rotates keys: an unknown kid refetches, at most once a minute.
        if kid not in self._keys and self.now() - self._loaded > 60 or self.now() - self._loaded > 86400:
            status, body = self.fetch(APPLE_ISSUER + "/auth/keys")
            if status == 200:
                self._keys = {key["kid"]: key for key in json.loads(body).get("keys", []) if key.get("kty") == "RSA"}
                self._loaded = self.now()
        key = self._keys.get(kid)
        if key is None:
            raise AccountError("unknown Apple signing key", 401)
        return key

    def verify(self, token, audience, identity=True):
        """The claims of an Apple-signed JWT for `audience`, or AccountError.
        An identity token names its user in `sub` and expires; a server
        notification names the user inside `events` and may carry only `iat`."""
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding, rsa
        try:
            head, body, signature = token.split(".")
            header, claims = json.loads(_b64decode(head)), json.loads(_b64decode(body))
            signature = _b64decode(signature)
        except (AttributeError, ValueError):
            raise AccountError("malformed Apple token", 401)
        if header.get("alg") != "RS256":
            raise AccountError("unexpected Apple token algorithm", 401)
        key = self._key(header.get("kid"))
        public = rsa.RSAPublicNumbers(int.from_bytes(_b64decode(key["e"]), "big"),
                                      int.from_bytes(_b64decode(key["n"]), "big")).public_key()
        try:
            public.verify(signature, f"{head}.{body}".encode(), padding.PKCS1v15(), hashes.SHA256())
        except InvalidSignature:
            raise AccountError("invalid Apple token signature", 401)
        audiences = claims.get("aud") if isinstance(claims.get("aud"), list) else [claims.get("aud")]
        if claims.get("iss") != APPLE_ISSUER or audience not in audiences:
            raise AccountError("Apple token is not for this app", 401)
        expires = claims.get("exp")
        if expires is None and not identity and isinstance(claims.get("iat"), (int, float)):
            expires = claims["iat"] + 86400
        if not isinstance(expires, (int, float)) or expires < self.now() - 60:
            raise AccountError("Apple token expired", 401)
        if identity and (not isinstance(claims.get("sub"), str) or not claims["sub"]):
            raise AccountError("Apple token has no subject", 401)
        return claims

    def client_secret(self, settings):
        """The ES256 JWT that stands for the app in /auth/token and /auth/revoke,
        or None while no Sign in with Apple key is configured."""
        if not (settings["teamID"] and settings["keyID"] and settings["keyPath"]):
            return None
        key = apns.ES256Key.from_file(settings["keyPath"])
        issued = int(self.now())
        header = apns._b64url(json.dumps({"alg": "ES256", "kid": settings["keyID"]}, separators=(",", ":")).encode())
        claims = apns._b64url(json.dumps({"iss": settings["teamID"], "iat": issued, "exp": issued + 300,
                                          "aud": APPLE_ISSUER, "sub": settings["bundleID"]}, separators=(",", ":")).encode())
        signing_input = header + b"." + claims
        return (signing_input + b"." + apns._b64url(key.sign(signing_input))).decode()

    def _form(self, path, fields):
        data = urllib.parse.urlencode(fields).encode()
        return self.fetch(APPLE_ISSUER + path, data, {"Content-Type": "application/x-www-form-urlencoded"})

    def exchange(self, code, settings):
        """The refresh token behind an authorization code: what a later
        account deletion revokes. Empty when that cannot be had."""
        secret = self.client_secret(settings)
        if not secret or not code:
            return ""
        status, body = self._form("/auth/token", {"client_id": settings["bundleID"], "client_secret": secret,
                                                  "code": code, "grant_type": "authorization_code"})
        if status != 200:
            print(f"Sign in with Apple token exchange failed: HTTP {status}")
            return ""
        return json.loads(body).get("refresh_token", "")

    def revoke(self, token, settings):
        secret = self.client_secret(settings)
        if not secret or not token:
            return False
        status, _ = self._form("/auth/revoke", {"client_id": settings["bundleID"], "client_secret": secret,
                                                "token": token, "token_type_hint": "refresh_token"})
        return status == 200


class Accounts:
    def __init__(self, db, lock, now=time.time, apple=None, vault=None):
        self.db, self.lock, self.now = db, lock, now
        self.apple = apple or AppleIdentity(now=now)
        self.vault = vault
        # Called with the devices whose entitlement may have grown (None: all),
        # so their pending reminders are queued again (the Live Activity service).
        self.on_change = lambda devices: None
        with self.lock:
            self.db.executescript(SCHEMA)
            if "name" not in {row[1] for row in self.db.execute("PRAGMA table_info(accounts)")}:
                self.db.execute("ALTER TABLE accounts ADD COLUMN name TEXT NOT NULL DEFAULT ''")
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

    # MARK: Settings

    def settings(self, db=None):
        db = db or self.db
        with self.lock:
            stored = {row[0]: json.loads(row[1]) for row in db.execute("SELECT key,value FROM account_settings")}
        return {**SETTINGS, **{key: value for key, value in stored.items() if key in SETTINGS}}

    def save_settings(self, value):
        if not isinstance(value, dict) or set(value) - set(SETTINGS):
            raise AccountError(f"settings keys are {', '.join(SETTINGS)}")
        clean = {}
        for key, item in value.items():
            if key == "trialDays":
                if type(item) is not int or not 0 <= item <= 365:
                    raise AccountError("trialDays must be 0–365")
            elif not isinstance(item, str) or len(item) > 500:
                raise AccountError(f"{key} must be text")
            elif key == "enforceAfter" and item:
                try: datetime.strptime(item, "%Y-%m-%d")
                except ValueError: raise AccountError("enforceAfter must be YYYY-MM-DD or empty")
            clean[key] = item.strip() if isinstance(item, str) else item
        if clean.get("keyPath"):
            try: apns.ES256Key.from_file(clean["keyPath"])  # a wrong path fails here, not at the next deletion
            except apns.APNsError as error: raise AccountError(str(error))
        before = self.settings()
        with self.transaction() as db:
            for key, item in clean.items():
                db.execute("INSERT INTO account_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           (key, json.dumps(item)))
            self._audit(db, "settings", {key: item for key, item in clean.items() if key != "keyPath"})
        if clean.get("enforceAfter", before["enforceAfter"]) != before["enforceAfter"]:
            # Enforcement ending or moving later frees everyone's pending
            # reminders, signed in or not: None stands for every device.
            self.on_change(None)
        return self.admin_settings()

    def admin_settings(self):
        value = self.settings()
        value["signInConfigured"] = bool(value["teamID"] and value["keyID"] and value["keyPath"])
        return value

    def _audit(self, db, action, detail):
        db.execute("INSERT INTO account_audit(action,detail,created_at) VALUES(?,?,?)",
                   (action, json.dumps(detail, ensure_ascii=False), self.now()))

    # MARK: Entitlement

    def enforced(self, day, settings=None):
        after = (settings or self.settings())["enforceAfter"]
        return bool(after) and day >= after

    def _subscribed_until(self, db, account):
        row = db.execute("SELECT MAX(expires_at) FROM subscriptions WHERE account=? AND revoked=0", (account,)).fetchone()
        return row[0] if row and row[0] and row[0] > self.now() else None

    def _balance(self, db, account):
        credited = db.execute("SELECT COALESCE(SUM(days),0) FROM credit_ledger WHERE account=?", (account,)).fetchone()[0]
        used = db.execute("SELECT COUNT(*) FROM usage_charges WHERE account=?", (account,)).fetchone()[0]
        return credited - used

    def _active(self, db, account, day):
        if self._subscribed_until(db, account):
            return True
        if db.execute("SELECT 1 FROM usage_charges WHERE account=? AND day=?", (account, day)).fetchone():
            return True  # the day is paid for already
        return self._balance(db, account) > 0

    def _account_of(self, db, device):
        row = db.execute("SELECT account FROM account_devices WHERE device=?", (device,)).fetchone()
        return row[0] if row else None

    def allows(self, db, device, day):
        """Whether `device` may get a reminder on UTC+8 `day` (ISO date).
        Runs inside the caller's transaction."""
        if not self.enforced(day):
            return True
        account = self._account_of(db, device)
        return account is not None and self._active(db, account, day)

    def charge(self, db, device, day):
        """A reminder of `device` started on `day`: the day costs its account
        one credit day, once, unless it is free or subscribed."""
        if not self.enforced(day):
            return
        account = self._account_of(db, device)
        if account is None or self._subscribed_until(db, account):
            return
        db.execute("INSERT OR IGNORE INTO usage_charges VALUES(?,?,?)", (account, day, self.now()))

    def entitlement(self, db, account):
        settings = self.settings(db)
        today = _day(self.now())
        until = self._subscribed_until(db, account)
        charged = bool(db.execute("SELECT 1 FROM usage_charges WHERE account=? AND day=?", (account, today)).fetchone())
        balance = self._balance(db, account)
        enforced = self.enforced(today, settings)
        source = ("free" if not enforced else "subscription" if until else
                  "credit" if charged or balance > 0 else None)
        return {"active": source is not None, "source": source, "creditDays": max(0, balance),
                "chargedToday": charged, "subscriptionExpiresAt": until,
                "enforced": enforced, "enforceAfter": settings["enforceAfter"]}

    # MARK: Sign in

    def nonce(self):
        """A single-use nonce: the app hands its SHA-256 to Apple, and Apple
        signs that hash into the identity token."""
        raw = secrets.token_urlsafe(24)
        with self.transaction() as db:
            db.execute("DELETE FROM account_nonces WHERE expires_at<?", (self.now(),))
            db.execute("INSERT INTO account_nonces VALUES(?,?)", (_digest(raw), self.now() + NONCE_TTL))
        return {"nonce": raw, "expiresIn": NONCE_TTL}

    def sign_in(self, value):
        if not isinstance(value, dict) or not isinstance(value.get("identityToken"), str) or not isinstance(value.get("nonce"), str):
            raise AccountError("expected identityToken and nonce")
        code = value.get("authorizationCode", "")
        if not isinstance(code, str):
            raise AccountError("authorizationCode must be text")
        settings = self.settings()
        claims = self.apple.verify(value["identityToken"], settings["bundleID"])
        hashed = _digest(value["nonce"])
        if claims.get("nonce") != hashed:
            raise AccountError("nonce mismatch", 401)
        with self.transaction() as db:
            if not db.execute("DELETE FROM account_nonces WHERE hash=? AND expires_at>=?", (hashed, self.now())).rowcount:
                raise AccountError("nonce expired or used", 401)
        # Outside the transaction: a network round trip to Apple.
        refresh = self.apple.exchange(code, settings)
        sealed = self.vault.seal(refresh) if refresh and self.vault and self.vault.cipher else ""
        apple_hash = _digest("siwa:" + claims["sub"])
        token = secrets.token_urlsafe(32)
        now = self.now()
        with self.transaction() as db:
            row = db.execute("SELECT id FROM accounts WHERE apple_hash=?", (apple_hash,)).fetchone()
            if row is None:
                account = secrets.token_hex(16)
                db.execute("INSERT INTO accounts(id,code,apple_hash,refresh_token,created_at,last_seen) VALUES(?,?,?,?,?,?)",
                           (account, self._new_code(db), apple_hash, sealed, now, now))
                # One free trial per Apple ID, even after the account is deleted.
                if db.execute("INSERT OR IGNORE INTO trial_claims VALUES(?,?)", (apple_hash, now)).rowcount and settings["trialDays"]:
                    db.execute("INSERT INTO credit_ledger(account,days,reason,created_at) VALUES(?,?,'trial',?)",
                               (account, settings["trialDays"], now))
            else:
                account = row[0]
                if sealed:
                    db.execute("UPDATE accounts SET refresh_token=? WHERE id=?", (sealed, account))
            db.execute("UPDATE accounts SET last_seen=? WHERE id=?", (now, account))
            db.execute("DELETE FROM account_sessions WHERE last_used<?", (now - SESSION_TTL,))
            db.execute("INSERT INTO account_sessions VALUES(?,?,?,?)", (_digest(token), account, now, now))
        return {"session": token, "account": self.summary(account)}

    def _new_code(self, db):
        while True:
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
            if not db.execute("SELECT 1 FROM accounts WHERE code=?", (code,)).fetchone():
                return code

    def authenticate(self, header):
        """The account behind an `Authorization: Bearer` session, or 401."""
        token = header[7:].strip() if isinstance(header, str) and header[:7].lower() == "bearer " else ""
        if not token:
            raise AccountError("sign in required", 401)
        now = self.now()
        with self.transaction() as db:
            row = db.execute("SELECT account FROM account_sessions WHERE token_hash=? AND last_used>=?",
                             (_digest(token), now - SESSION_TTL)).fetchone()
            if row is None:
                raise AccountError("session expired", 401)
            db.execute("UPDATE account_sessions SET last_used=? WHERE token_hash=?", (now, _digest(token)))
            db.execute("UPDATE accounts SET last_seen=? WHERE id=?", (now, row[0]))
        return row[0]

    def summary(self, account):
        with self.lock:
            row = self.db.execute("SELECT * FROM accounts WHERE id=?", (account,)).fetchone()
            devices = self.db.execute("SELECT COUNT(*) FROM account_devices WHERE account=?", (account,)).fetchone()[0]
            return {"code": row["code"], "name": row["name"], "createdAt": row["created_at"], "devices": devices,
                    "avatar": self.avatar_path(account), "entitlement": self.entitlement(self.db, account)}

    def sign_out(self, header):
        token = header[7:].strip() if isinstance(header, str) and header[:7].lower() == "bearer " else ""
        with self.transaction() as db:
            db.execute("DELETE FROM account_sessions WHERE token_hash=?", (_digest(token),))
        return {"signedOut": True}

    def bind(self, account, device):
        """Reminders of `device` now count against `account`. A device moves
        from any account it was on before."""
        with self.transaction() as db:
            db.execute("INSERT INTO account_devices VALUES(?,?,?) ON CONFLICT(device) DO UPDATE SET account=excluded.account,bound_at=excluded.bound_at",
                       (device, account, self.now()))
        self.on_change([device])
        return self.summary(account)

    def unbind(self, account, device):
        with self.transaction() as db:
            db.execute("DELETE FROM account_devices WHERE device=? AND account=?", (device, account))
        return self.summary(account)

    def delete(self, account, revoke=True):
        """Remove the account and everything tied to it; only the trial claim
        stays, so a new account on the same Apple ID gets no second trial."""
        with self.lock:
            row = self.db.execute("SELECT refresh_token FROM accounts WHERE id=?", (account,)).fetchone()
        if row is None:
            return {"deleted": False}
        revoked = False
        if revoke and row[0] and self.vault and self.vault.cipher:
            try:
                revoked = self.apple.revoke(self.vault.open(row[0]), self.settings())
            except Exception as error:
                print(f"Sign in with Apple revoke failed: {type(error).__name__}: {error}")
        with self.transaction() as db:
            for table in ("account_sessions", "account_devices", "account_avatars", "credit_ledger", "usage_charges", "subscriptions"):
                db.execute(f"DELETE FROM {table} WHERE account=?", (account,))
            db.execute("DELETE FROM accounts WHERE id=?", (account,))
            self._audit(db, "delete", {"revoked": revoked})
        return {"deleted": True}

    # MARK: Avatar
    #
    # Sign in with Apple has no photo: the user picks one in the app. It is
    # public by an unguessable path that changes with every upload, so readers
    # may cache it for good.

    def set_profile(self, account, value):
        """The nickname the user picks: shown beside the avatar and used as the
        publisher of the shares they make. Apple's name is never asked for."""
        if not isinstance(value, dict) or set(value) != {"name"} or not isinstance(value["name"], str):
            raise AccountError("expected name")
        name = " ".join(value["name"].split())
        if len(name) > 20:
            raise AccountError("name must be at most 20 characters")
        with self.transaction() as db:
            db.execute("UPDATE accounts SET name=? WHERE id=?", (name, account))
        return self.summary(account)

    def set_avatar(self, account, value):
        if not isinstance(value, dict) or set(value) != {"image"} or not isinstance(value["image"], str):
            raise AccountError("expected image (base64)")
        try: data = base64.b64decode(value["image"], validate=True)
        except ValueError: raise AccountError("image is not base64")
        if not data or len(data) > AVATAR_BYTES:
            raise AccountError(f"image must be at most {AVATAR_BYTES // 1024} KB")
        mime = next((kind for magic, kind in AVATAR_TYPES if data.startswith(magic)), None)
        if mime is None:
            raise AccountError("image must be JPEG or PNG")
        with self.transaction() as db:
            db.execute("INSERT INTO account_avatars VALUES(?,?,?,?,?) ON CONFLICT(account) DO UPDATE SET "
                       "version=excluded.version,mime=excluded.mime,data=excluded.data,updated_at=excluded.updated_at",
                       (account, secrets.token_hex(12), mime, data, self.now()))
        return self.summary(account)

    def clear_avatar(self, account):
        with self.transaction() as db:
            db.execute("DELETE FROM account_avatars WHERE account=?", (account,))
        return self.summary(account)

    def avatar_path(self, account):
        with self.lock:
            row = self.db.execute("SELECT version FROM account_avatars WHERE account=?", (account,)).fetchone()
        return f"/v1/avatars/{row[0]}" if row else None

    def avatar(self, version):
        """(mime, bytes) of a published avatar, or None."""
        with self.lock:
            row = self.db.execute("SELECT mime,data FROM account_avatars WHERE version=?", (version,)).fetchone()
        return (row[0], bytes(row[1])) if row else None

    def admin_clear_avatar(self, code):
        with self.lock:
            row = self.db.execute("SELECT id FROM accounts WHERE code=?", (code.upper(),)).fetchone()
        if row is None:
            raise AccountError("account not found", 404)
        with self.transaction() as db:
            db.execute("DELETE FROM account_avatars WHERE account=?", (row[0],))
            self._audit(db, "clearAvatar", {"code": code.upper()})
        return self.admin_detail(code)

    def apple_event(self, value):
        """Sign in with Apple server-to-server notifications."""
        if not isinstance(value, dict) or not isinstance(value.get("payload"), str):
            raise AccountError("expected payload")
        claims = self.apple.verify(value["payload"], self.settings()["bundleID"], identity=False)
        event = claims.get("events")
        event = json.loads(event) if isinstance(event, str) else event
        if not isinstance(event, dict) or not isinstance(event.get("sub"), str):
            raise AccountError("unexpected event")
        with self.lock:
            row = self.db.execute("SELECT id FROM accounts WHERE apple_hash=?", (_digest("siwa:" + event["sub"]),)).fetchone()
        if row is None:
            return {"handled": False}
        if event.get("type") == "account-delete":
            self.delete(row[0], revoke=False)
        elif event.get("type") == "consent-revoked":
            # The user stopped using Sign in with Apple here: signed out everywhere.
            with self.transaction() as db:
                db.execute("DELETE FROM account_sessions WHERE account=?", (row[0],))
                db.execute("DELETE FROM account_devices WHERE account=?", (row[0],))
        return {"handled": True}

    # MARK: Admin

    def _devices(self, accounts=None):
        with self.lock:
            if accounts is None:
                return [row[0] for row in self.db.execute("SELECT device FROM account_devices")]
            marks = ",".join("?" * len(accounts))
            return [row[0] for row in self.db.execute(f"SELECT device FROM account_devices WHERE account IN ({marks})", accounts)]

    def _rows(self, where="", params=()):
        now = self.now()
        rows = self.db.execute(f"""
            SELECT a.id, a.code, a.name, a.created_at, a.last_seen,
             COALESCE((SELECT SUM(days) FROM credit_ledger c WHERE c.account=a.id),0) AS credited,
             (SELECT COUNT(*) FROM usage_charges u WHERE u.account=a.id) AS used,
             (SELECT MAX(day) FROM usage_charges u WHERE u.account=a.id) AS last_charged,
             (SELECT MAX(expires_at) FROM subscriptions s WHERE s.account=a.id AND s.revoked=0) AS subscribed_until,
             (SELECT COUNT(*) FROM account_devices d WHERE d.account=a.id) AS devices
            FROM accounts a {where} ORDER BY a.created_at DESC""", params).fetchall()
        result = []
        for row in rows:
            balance = row["credited"] - row["used"]
            until = row["subscribed_until"] if row["subscribed_until"] and row["subscribed_until"] > now else None
            status = "subscribed" if until else "trial" if balance > 0 else "expired"
            result.append({"id": row["id"], "code": row["code"], "name": row["name"], "createdAt": row["created_at"], "lastSeen": row["last_seen"],
                           "status": status, "creditDays": max(0, balance), "usedDays": row["used"],
                           "lastChargedDay": row["last_charged"], "subscriptionExpiresAt": until, "devices": row["devices"]})
        return result

    def admin_summary(self):
        with self.lock:
            rows = self._rows()
            week = _day(self.now() - 7 * 86400)
            charged = self.db.execute("SELECT COUNT(DISTINCT account) FROM usage_charges WHERE day>=?", (week,)).fetchone()[0]
        counts = {group: sum(1 for row in rows if row["status"] == group) for group in GROUPS[1:]}
        return {"accounts": len(rows), **counts, "chargedLast7Days": charged,
                "newLast7Days": sum(1 for row in rows if row["createdAt"] >= self.now() - 7 * 86400),
                "settings": self.admin_settings()}

    def admin_list(self, query=""):
        with self.lock:
            rows = self._rows(*(("WHERE a.code LIKE ?", (query.strip().upper() + "%",)) if query.strip() else ("", ())))
        return {"accounts": [{key: value for key, value in row.items() if key != "id"} for row in rows[:200]],
                "total": len(rows)}

    def admin_detail(self, code):
        with self.lock:
            rows = self._rows("WHERE a.code=?", (code.upper(),))
            if not rows:
                raise AccountError("account not found", 404)
            row = rows[0]
            ledger = [dict(item) for item in self.db.execute(
                "SELECT days,reason,note,created_at AS createdAt FROM credit_ledger WHERE account=? ORDER BY id DESC LIMIT 100", (row["id"],))]
            charges = [item[0] for item in self.db.execute(
                "SELECT day FROM usage_charges WHERE account=? ORDER BY day DESC LIMIT 60", (row["id"],))]
        return {**{key: value for key, value in row.items() if key != "id"}, "avatar": self.avatar_path(row["id"]),
                "ledger": ledger, "chargedDays": charges}

    def grant(self, value):
        """Credit usage days to one account (`code`) or a group. `dryRun`
        only counts who would get them."""
        if not isinstance(value, dict):
            raise AccountError("expected an object")
        target, days, note = value.get("target"), value.get("days"), value.get("note", "")
        if target != "account" and target not in GROUPS:
            raise AccountError(f"target must be account or one of {', '.join(GROUPS)}")
        if type(days) is not int or days == 0 or not -365 <= days <= 365:
            raise AccountError("days must be a non-zero whole number within ±365")
        if not isinstance(note, str) or len(note) > 200:
            raise AccountError("note must be text up to 200 characters")
        with self.lock:
            if target == "account":
                if not isinstance(value.get("code"), str):
                    raise AccountError("code required")
                rows = self._rows("WHERE a.code=?", (value["code"].strip().upper(),))
                if not rows:
                    raise AccountError("account not found", 404)
            else:
                rows = [row for row in self._rows() if target == "all" or row["status"] == target]
        if value.get("dryRun") is True:
            return {"accounts": len(rows), "days": days}
        batch = secrets.token_hex(8)
        with self.transaction() as db:
            db.executemany("INSERT INTO credit_ledger(account,days,reason,note,batch,created_at) VALUES(?,?,'grant',?,?,?)",
                           [(row["id"], days, note.strip(), batch, self.now()) for row in rows])
            self._audit(db, "grant", {"target": target, "code": value.get("code"), "days": days,
                                      "note": note.strip(), "accounts": len(rows), "batch": batch})
        if days > 0 and rows:
            self.on_change(self._devices([row["id"] for row in rows]))
        return {"accounts": len(rows), "days": days, "batch": batch}
