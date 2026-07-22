#!/bin/bash
# Apply the Poppy Bank Epicenter captive-portal design to a FlawkDetection device.
#
#   wget -qO /tmp/apply.sh https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main/apply.sh
#   bash /tmp/apply.sh
#
# Idempotent - safe to re-run. Does NOT restart nodogsplash, so guests already
# online are never disconnected (nodogsplash re-reads splash.html per request).
set -euo pipefail

BASE="${BASE:-https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main}"
HTDOCS=/etc/nodogsplash/htdocs
STOCK_FLAWK_MD5=ce397427d9b88b716ff44e1d4db0b24f
EPICENTER_SPLASH_MD5=cd3aa0a9aaba8fa4525df77fb62aeefb

STAGE=$(mktemp -d /tmp/epicenter.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

# --- fetch helper: device images ship wget but NOT curl; python3 is the fallback ---
fetch() { # fetch <url> <dest>
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" "$1" "$2"
  else
    echo "FAIL: neither wget nor python3 available to download." >&2; return 1
  fi
}

echo "== 1. Pre-flight =="
[ -d "$HTDOCS" ] || { echo "FAIL: $HTDOCS missing - is nodogsplash installed?"; exit 1; }
if grep -qE '^[[:space:]]*(WebRoot|SplashPage)' /etc/nodogsplash/nodogsplash.conf 2>/dev/null; then
  echo "FAIL: WebRoot/SplashPage is overridden in nodogsplash.conf, so the served"
  echo "      payload is NOT $HTDOCS. Resolve manually."; exit 1
fi
CUR=$(md5sum "$HTDOCS/splash.html" | cut -d' ' -f1)
if [ "$CUR" = "$EPICENTER_SPLASH_MD5" ]; then
  echo "  Epicenter design is ALREADY applied. Re-running is harmless."
elif [ "$CUR" != "$STOCK_FLAWK_MD5" ]; then
  echo "  WARNING: current splash.html is neither stock Flawk nor Epicenter."
  echo "           md5=$CUR - this device may carry a bespoke design."
  if [ -e /dev/tty ]; then
    read -r -p "  Overwrite anyway? [y/N] " a </dev/tty
    [ "$a" = "y" ] || { echo "  Aborted."; exit 1; }
  else
    echo "  No tty for confirmation - aborting. Re-run interactively to override."; exit 1
  fi
fi

echo "== 2. Download payload =="
mkdir -p "$STAGE/images"
for f in splash.html status.html images/epicenter.png; do
  echo "  fetching $f"
  fetch "$BASE/$f" "$STAGE/$f"
done
fetch "$BASE/MD5SUMS" "$STAGE/MD5SUMS"

echo "== 3. Verify downloaded payload =="
# Catches truncated/partial downloads and any proxy that mangled the files.
( cd "$STAGE" && md5sum -c --quiet MD5SUMS ) \
  || { echo "FAIL: download is corrupt. Nothing was changed."; exit 1; }
echo "  payload md5-verified"

echo "== 4. Backup =="
BK="/etc/nodogsplash/htdocs.bak.$(date +%Y%m%d-%H%M%S)"
sudo cp -a "$HTDOCS" "$BK"
echo "  backup: $BK"

echo "== 5. Apply overlay =="
rm -f "$STAGE/MD5SUMS"
# The trailing "/." copies the CONTENTS of $STAGE. Without it, cp nests the
# directory inside htdocs, exits 0, and the portal silently keeps serving the
# old design with no error anywhere.
sudo cp -r "$STAGE/." "$HTDOCS/"
sudo chown root:root "$HTDOCS/splash.html" "$HTDOCS/status.html" "$HTDOCS/images/epicenter.png"
sudo chmod 644 "$HTDOCS/splash.html" "$HTDOCS/status.html" "$HTDOCS/images/epicenter.png"

echo "== 6. Verify live payload =="
LIVE_OK=1
for pair in "splash.html:$EPICENTER_SPLASH_MD5" \
            "status.html:4dd88045a8697ae9fc8bb940ea28a4e9" \
            "images/epicenter.png:dc764534114d03c44830258f198921fb"; do
  f="${pair%%:*}"; want="${pair##*:}"
  got=$(md5sum "$HTDOCS/$f" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "  MISMATCH $f ($got)"; LIVE_OK=0; }
done
[ "$LIVE_OK" = 1 ] || { echo "FAIL: rollback with: sudo cp -a $BK/. $HTDOCS/"; exit 1; }
# These come only from `make install` and never return if lost.
for f in splash.css images/splash.jpg images/background.jpeg; do
  [ -f "$HTDOCS/$f" ] || echo "  WARNING: stock file $f is missing"
done
echo "  live payload md5-verified"

echo
echo "SUCCESS - Epicenter design applied."
echo "nodogsplash was NOT restarted; the change is live on the next request."
echo "Rollback: sudo cp -a $BK/. $HTDOCS/"
