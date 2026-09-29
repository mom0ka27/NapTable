"""Which devices may get Live Activity reminders.

There are no accounts: a subscription is the App Store's, on the user's Apple
ID, and each device that sees it is marked here by its Live Activity device id
(`device_subscriptions`, filled once StoreKit verification arrives in phase 2).
The free first month is Apple's introductory offer.

`requireSubscription` off, as during the beta, lets every device in for free.
"""
from contextlib import contextmanager
import json
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS device_subscriptions (
 device TEXT NOT NULL, original_transaction TEXT NOT NULL, product TEXT NOT NULL,
 environment TEXT NOT NULL, expires_at REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL,
 PRIMARY KEY(device, original_transaction)
);
CREATE INDEX IF NOT EXISTS device_subscriptions_transaction ON device_subscriptions(original_transaction);
CREATE TABLE IF NOT EXISTS subscription_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""
# Sign in with Apple accounts were removed; whatever they left behind goes.
RETIRED = ("accounts", "account_sessions", "account_devices", "account_nonces", "account_avatars",
           "account_audit", "credit_ledger", "usage_charges", "trial_claims", "subscriptions")

SETTINGS = {"requireSubscription": False}


class SubscriptionError(ValueError):
    pass


class Subscriptions:
    def __init__(self, db, lock, now=time.time):
        self.db, self.lock, self.now = db, lock, now
        # Called with the devices that may have become entitled (None: all), so
        # their pending reminders are queued again (the Live Activity service).
        self.on_change = lambda devices: None
        with self.lock:
            self.db.executescript(SCHEMA)
            if self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='account_settings'").fetchone():
                # The switch lived with the accounts: keep its value.
                row = self.db.execute("SELECT value FROM account_settings WHERE key='requireSubscription'").fetchone()
                if row:
                    self.db.execute("INSERT OR IGNORE INTO subscription_settings VALUES('requireSubscription',?)", (row[0],))
                self.db.execute("DROP TABLE account_settings")
            for table in RETIRED:
                self.db.execute(f"DROP TABLE IF EXISTS {table}")
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

    def settings(self):
        with self.lock:
            stored = {row[0]: json.loads(row[1]) for row in self.db.execute("SELECT key,value FROM subscription_settings")}
        return {**SETTINGS, **{key: value for key, value in stored.items() if key in SETTINGS}}

    def save_settings(self, value):
        if not isinstance(value, dict) or set(value) - set(SETTINGS):
            raise SubscriptionError(f"settings keys are {', '.join(SETTINGS)}")
        if "requireSubscription" in value and type(value["requireSubscription"]) is not bool:
            raise SubscriptionError("requireSubscription must be true or false")
        before = self.settings()
        with self.transaction() as db:
            for key, item in value.items():
                db.execute("INSERT INTO subscription_settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           (key, json.dumps(item)))
        if value.get("requireSubscription", before["requireSubscription"]) != before["requireSubscription"]:
            # Turned off, it frees every device's pending reminders.
            self.on_change(None)
        return self.settings()

    # MARK: Entitlement

    def required(self):
        return self.settings()["requireSubscription"]

    def _until(self, db, device):
        row = db.execute("SELECT MAX(expires_at) FROM device_subscriptions WHERE device=? AND revoked=0", (device,)).fetchone()
        return row[0] if row and row[0] and row[0] > self.now() else None

    def allows(self, db, device, day):
        """Whether `device` may get a reminder on UTC+8 `day` (ISO date).
        Runs inside the caller's transaction."""
        return not self.required() or self._until(db, device) is not None

    def entitlement(self, db, device):
        """For the device status: what the app shows about its subscription."""
        required, until = self.required(), self._until(db, device)
        return {"required": required, "subscriptionExpiresAt": until,
                "source": "subscription" if until else None if required else "free"}

    # MARK: Admin

    def admin_summary(self):
        with self.lock:
            devices = self.db.execute("SELECT COUNT(DISTINCT device) FROM device_subscriptions WHERE revoked=0 AND expires_at>?",
                                      (self.now(),)).fetchone()[0]
        return {"subscribedDevices": devices, "settings": self.settings()}
