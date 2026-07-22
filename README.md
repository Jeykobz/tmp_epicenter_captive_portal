# Epicenter captive portal — temporary distribution repo

Moves the Poppy Bank Epicenter captive-portal onto deployed FlawkDetection devices that
have **no SSH access** — the operator runs a one-line `wget | sudo bash` on the device.
Source of truth is the package `FlawkDetection_3.0.2/`; this repo is a delivery shim.

There are two levels of change here — pick the one you need:

| Script | What it does | Restarts nodogsplash? |
|---|---|---|
| **`install.sh`** | **Full patch-supported portal**: patched nodogsplash binary (durable guest spool + `sms_on` consent + segfault/CSV-injection fixes) **+** consent-fixed splash **+** `guest_forwarder.py` + config + 30 s delivery cron. | Yes (health-gated, auto-rollback) |
| `apply.sh` | Theme only — overlays `splash.html` / `status.html` / logo. | No |
| `fix_ap_24ghz.sh` | Unrelated radio fix: moves the AP from 5 GHz ch36 to 2.4 GHz + sets a regulatory domain. | Yes |

## Install the full patch-supported portal

On the device (images ship `wget`, **not** `curl`):

```bash
wget -qO /tmp/install.sh https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main/install.sh
sudo bash /tmp/install.sh
```

What it does, in order: pre-flight (toolchain, source, config present) → clone + md5-verify
this repo → back up the binary, htdocs and sources under one timestamp → **build the patched
nodogsplash in `/tmp`** (device source untouched on failure) → **swap `/usr/bin/nodogsplash`
only behind a runtime health check** (active + listening on `:2050`), auto-rolling-back to the
original binary if it doesn't come up → overlay the consent-fixed splash → install
`guest_forwarder.py` + config → append the 30 s delivery cron (idempotent) → run the forwarder
once and print a PASS block with rollback instructions.

**It never leaves the portal broken:** the live binary is only kept if the daemon comes up
healthy with it; otherwise the backup is restored and re-verified before the script exits.
Idempotent — safe to re-run.

Defaults deliver to **devcms** immediately. Override per run:

```bash
sudo ENDPOINT=https://cms.flawkai.com/api/router/guests DRY_RUN=true bash /tmp/install.sh
```

- `ENDPOINT` — CMS ingest URL (default `https://devcms.flawkai.com/api/router/guests`).
- `DRY_RUN` — `true` = forwarder logs the payload but sends nothing; `false` (default) = deliver.

### Delivery depends on the device's api_key being registered

The forwarder authenticates with the device's **own** `api_key` from
`/FlawkDetection/configuration.json` (the same key the box's other CMS senders use, via the
`x-api-key` header). That key must exist in the target CMS's `users.live_api_key` column, or
POSTs return **401** and are retried forever — guests are still captured and spooled and the
portal is unaffected, only CMS/Patch delivery waits. The installer prints this device's
`place_id` and a masked key so you can confirm it is registered.

## Theme-only (legacy) and the AP fix

`apply.sh` overlays just the design (backup + md5-verify + overlay, no restart). `fix_ap_24ghz.sh`
is a separate radio fix (auto-detects the interface, surveys 2.4 GHz, gates on the AP coming
back up, auto-rolls-back, persists into `AP.sh`). See the script headers for details and env
overrides. `install.sh` supersedes `apply.sh` for the Epicenter rollout.

## Consent fix is included

The shipped `splash.html` names both checkboxes and makes **marketing opt-in optional**
(`name="sms_on"`, not `required`) while keeping terms `required` (`name="terms"`) — TCPA/CTIA:
SMS consent may not be conditioned on WiFi. The patched nodogsplash threads `sms_on` through the
auth path and records it with each guest; consent enforcement happens server-side in the CMS.

## Do not change the field names

`Flawk-5G/capture_webpages.py` reads `registered_clients.csv` **positionally** (`row[3]`,
`row[4]`, `row[5]`). Renaming the `email`, `phone` or `firstname` inputs silently produces blank
columns with no error anywhere.

## Contents

| File | Purpose |
|---|---|
| `install.sh` | Full patch-supported portal installer (self-verifying, auto-rollback). |
| `payload/nodogsplash-src/{auth.c,auth.h,http_microhttpd.c,ndsctl_thread.c}` | The 4 patched nodogsplash sources; built on-device. |
| `payload/guest_forwarder.py` | Delivers spooled guests to the CMS. |
| `payload/MD5SUMS` | Integrity manifest for the code payload. |
| `splash.html` / `status.html` / `images/epicenter.png` | Consent-fixed Epicenter theme (also used by `apply.sh`). |
| `MD5SUMS` | Integrity manifest for the theme. |
| `apply.sh` | Theme-only overlay. |
| `fix_ap_24ghz.sh` | 5 GHz→2.4 GHz AP fix. |

`.gitattributes` sets `* -text` so git never rewrites line endings — EOL conversion would change
the md5s and break every integrity check.

## Known gaps (not fixed by this overlay)

- `nodogsplash.conf` hardcodes `RedirectURL` to `flawkai.com`, so guests land on a Flawk-branded
  page after login. Changing it needs a nodogsplash restart (which `install.sh` already does, so
  a future version could bundle it).
- The Terms & Conditions body still names "Flawk" as the legal entity.

## Clean-up

Temporary public repo. Delete it once the pipeline ships in the package installer
(`setup.py` → Portal Design), after which devices are provisioned rather than patched by hand.
