# Epicenter captive-portal theme (temporary distribution repo)

Poppy Bank Epicenter design for the nodogsplash captive portal on FlawkDetection
devices. This repo exists **only to move these files onto deployed devices that
have no SSH access**. It is not the source of truth — that is
`FlawkDetection_3.0.2/Flawk-5G/htdocs_themes/epicenter/`.

## Apply to a device

On the device (needs `sudo`; the images ship `wget` but **not** `curl`):

```bash
wget -qO /tmp/apply.sh https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main/apply.sh
bash /tmp/apply.sh
```

The script backs up the current payload, downloads and md5-verifies the theme,
overlays it, then verifies the live result. It is idempotent, and it **does not
restart nodogsplash** — the daemon re-reads `splash.html` per request, so the
change goes live on the next connection without dropping guests already online.

If anything fails it aborts before touching `/etc`, and prints the rollback:

```bash
sudo cp -a /etc/nodogsplash/htdocs.bak.<timestamp>/. /etc/nodogsplash/htdocs/
```

## Contents

| File | Purpose |
|---|---|
| `splash.html` | Pre-auth splash page. Preserves the nodogsplash `$authaction` / `$tok` / `$redir` variables and the `email` / `phone` / `firstname` field names. |
| `status.html` | Shown to already-authenticated clients. |
| `images/epicenter.png` | Epicenter logo. |
| `MD5SUMS` | Integrity manifest used by `apply.sh`. |
| `apply.sh` | Backup + download + verify + overlay. |

`.gitattributes` sets `* -text` so git never rewrites line endings. Without it,
`core.autocrlf` would alter the HTML bytes and every md5 check would fail.

## Do not change the field names

`Flawk-5G/capture_webpages.py` reads `registered_clients.csv` **positionally**
(`row[3]`, `row[4]`, `row[5]`). Renaming the `email`, `phone` or `firstname`
inputs silently produces blank columns with no error anywhere.

## Known gaps (not fixable from this overlay)

- `nodogsplash.conf` hardcodes `RedirectURL` to `flawkai.com`, so guests still
  land on a Flawk-branded page after login. Changing it requires a nodogsplash
  restart.
- The Terms & Conditions body still names "Flawk" as the legal entity.
- The marketing opt-in checkbox is `required`, i.e. consent is a condition of
  WiFi access — worth a compliance review.

## Clean-up

This is a temporary public repo. Delete it once the theme ships in the package
installer (`setup.py` → Portal Design dropdown), after which devices should be
provisioned rather than patched by hand.
