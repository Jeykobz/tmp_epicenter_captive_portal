""" Copyright Flawk 2024

Delivers captive-portal guest signups to the Flawk CMS (which is the single place
that knows how to forward consenting guests on to Patch Retention).

Design goals (this runs unattended on customer devices):
  * NEVER hang and NEVER crash -- a bad network or a bad CMS must not affect the
    captive portal in any way. The portal auth path does not depend on this script.
  * Durable + retryable. nodogsplash (auth.c) appends one JSON object per signup to
    guest_spool.jsonl and fsync's it. That file is NOT wiped on boot, unlike
    registered_clients.csv, so a guest who signs up just before a reboot is not lost.
  * Exactly-once delivery. Every delivered row's dedupe key is recorded in
    guest_delivered.txt; a key is only written after a 2xx, so a failed POST is simply
    retried on the next run.

The spool is the record of truth for EVERY guest (consenting or not). Consent
(sms_on) travels with each row; filtering/consent enforcement happens server-side in
the CMS where it is auditable -- never here.
"""

import json
import hashlib
import os
import sys
import fcntl

import requests

sys.path.insert(1, '/FlawkDetection/Logging')
from logging_handler import LoggerHandler

# Logging
Logger = LoggerHandler()

BASE_DIR = '/FlawkDetection/Flawk-5G'
CONFIG_PATH = os.path.join(BASE_DIR, 'guest_forwarder_config.json')
SPOOL_PATH = os.path.join(BASE_DIR, 'guest_spool.jsonl')
DELIVERED_PATH = os.path.join(BASE_DIR, 'guest_delivered.txt')
LOCK_PATH = os.path.join(BASE_DIR, 'guest_forwarder.lock')
# The device's own config -- same file (and same api_key) the other CMS senders read.
DEVICE_CONFIG_PATH = '/FlawkDetection/configuration.json'

# Hard limits so a single run is always bounded in time.
HTTP_TIMEOUT = 10          # seconds per POST (connect+read)
MAX_ROWS_PER_RUN = 100     # cap work per invocation; the rest go on the next tick


def load_config():
    """Return the config dict, or None if delivery should not run."""
    if not os.path.exists(CONFIG_PATH):
        # No config on the device yet -> stay disabled and silent-ish.
        Logger.info("guest_forwarder: no config file, nothing to do.")
        return None
    try:
        with open(CONFIG_PATH, 'r') as f:
            cfg = json.load(f)
    except Exception as e:
        Logger.error(f"guest_forwarder: could not read config: {e}")
        return None
    if not cfg.get('enabled', False):
        return None
    if not cfg.get('endpoint'):
        Logger.error("guest_forwarder: config has no endpoint.")
        return None
    return cfg


def load_device_identity():
    """Read the device's own credentials fresh from configuration.json -- the same file, and
    the same api_key, that DataHandler/slideshow_analytics_sender.py uses to authenticate its
    CMS pushes. Returns (api_key, place_id, org, device_id), or all-None if a required field is
    missing so the caller skips the run rather than POST unauthenticated."""
    try:
        with open(DEVICE_CONFIG_PATH, 'r') as f:
            cfg = json.load(f)
    except Exception as e:
        Logger.error(f"guest_forwarder: could not read {DEVICE_CONFIG_PATH}: {e}")
        return None, None, None, None

    api_key = str(cfg.get('api_key') or '').strip()
    place_id = str(cfg.get('place_id') or '').strip()
    org = str(cfg.get('org') or '').strip()
    device_id = str(cfg.get('device_id') or '').strip()

    missing = [name for name, val in
               (('api_key', api_key), ('place_id', place_id), ('org', org)) if not val]
    if missing:
        Logger.error(
            f"guest_forwarder: {', '.join(missing)} missing/empty in configuration -- skipping.")
        return None, None, None, None
    return api_key, place_id, org, device_id


def dedupe_key(row):
    """Stable key for a spool row: timestamp + mac + phone."""
    raw = "{}|{}|{}".format(row.get('ts', ''), row.get('mac', ''), row.get('phone', ''))
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def load_delivered():
    if not os.path.exists(DELIVERED_PATH):
        return set()
    try:
        with open(DELIVERED_PATH, 'r') as f:
            return set(line.strip() for line in f if line.strip())
    except Exception as e:
        Logger.error(f"guest_forwarder: could not read delivered file: {e}")
        return set()


def mark_delivered(key):
    """Append a key. fsync so a crash right after cannot re-send the row."""
    try:
        with open(DELIVERED_PATH, 'a') as f:
            f.write(key + "\n")
            f.flush()
            os.fsync(f.fileno())
    except Exception as e:
        Logger.error(f"guest_forwarder: could not record delivered key: {e}")


def read_spool_rows():
    """Yield (key, row) for every well-formed spool line. Malformed lines are skipped."""
    if not os.path.exists(SPOOL_PATH):
        return []
    rows = []
    try:
        with open(SPOOL_PATH, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    # A partially-written line will be complete on the next tick.
                    Logger.error("guest_forwarder: skipping malformed spool line.")
                    continue
                rows.append((dedupe_key(row), row))
    except Exception as e:
        Logger.error(f"guest_forwarder: could not read spool: {e}")
    return rows


def post_guest(cfg, identity, row):
    """POST one guest to the CMS. Returns True on 2xx, False otherwise. Never raises."""
    api_key, place_id, org, device_id = identity
    payload = {
        "device_id": device_id,
        "place_id": place_id,
        "org": org,
        "guest": {
            "ts": row.get('ts'),
            "mac": row.get('mac'),
            "ip": row.get('ip'),
            "email": row.get('email'),
            "phone": row.get('phone'),
            "firstname": row.get('firstname'),
            "lastname": row.get('lastname'),
            "sms_on": row.get('sms_on'),
        },
    }
    # Recycle the device's own live_api_key, sent the way the box's other CMS senders send it:
    # the x-api-key header (see DataHandler/slideshow_analytics_sender.py).
    headers = {"Content-Type": "application/json", "x-api-key": api_key}

    if cfg.get('dry_run', False):
        masked = ("*" * max(0, len(api_key) - 4)) + api_key[-4:] if api_key else "(none)"
        Logger.info(
            f"guest_forwarder DRY-RUN would POST {cfg['endpoint']} "
            f"[x-api-key {masked}]: {json.dumps(payload)}")
        return False  # dry-run never marks delivered, so a real run still delivers later

    try:
        resp = requests.post(cfg['endpoint'], json=payload, headers=headers, timeout=HTTP_TIMEOUT)
    except Exception as e:
        Logger.error(f"guest_forwarder: POST failed (will retry next run): {e}")
        return False

    if 200 <= resp.status_code < 300:
        return True

    Logger.error(f"guest_forwarder: CMS returned {resp.status_code} (will retry next run).")
    return False


def main():
    cfg = load_config()
    if cfg is None:
        return

    identity = load_device_identity()
    if identity[0] is None:
        return

    rows = read_spool_rows()
    if not rows:
        return

    delivered = load_delivered()
    sent = 0
    for key, row in rows:
        if sent >= MAX_ROWS_PER_RUN:
            break
        if key in delivered:
            continue
        if post_guest(cfg, identity, row):
            mark_delivered(key)
            delivered.add(key)
            sent += 1

    if sent:
        Logger.info(f"guest_forwarder: delivered {sent} guest(s).")


if __name__ == "__main__":
    # Single-instance guard: cron fires every minute, so make sure a slow run can never
    # pile up on top of itself. If the lock is held, just exit -- next tick will retry.
    try:
        lock_fp = open(LOCK_PATH, 'w')
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        # Another instance is running.
        sys.exit(0)

    try:
        main()
    except Exception as e:
        # Absolute last-resort guard: this script must never crash noisily on a device.
        try:
            Logger.error(f"guest_forwarder: unexpected error: {e}")
        except Exception:
            pass
    finally:
        try:
            fcntl.flock(lock_fp, fcntl.LOCK_UN)
            lock_fp.close()
        except Exception:
            pass
