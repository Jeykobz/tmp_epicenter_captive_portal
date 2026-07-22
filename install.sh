#!/bin/bash
# Install the PATCH-SUPPORTED Epicenter captive portal onto a FlawkDetection device.
#
# Upgrades a plain nodogsplash captive portal to the full guest-capture pipeline:
#   patched nodogsplash binary (durable spool + sms_on consent + segfault/CSV-injection fixes)
#   + consent-fixed Epicenter splash + guest_forwarder.py + config + 30s delivery cron.
#
# Run on the device (images ship wget, NOT curl):
#   wget -qO /tmp/install.sh https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main/install.sh
#   sudo bash /tmp/install.sh
#
# It builds the binary in /tmp and only swaps the live one after a passing runtime health
# check, auto-rolling-back otherwise -- it must never leave the portal broken. Idempotent.
#
# Env overrides:
#   ENDPOINT=https://cms.flawkai.com/api/router/guests   (default: devcms)
#   DRY_RUN=true                                         (default: false -> deliver now)
#   REPO_URL=... BRANCH=...                               (default: this repo / main)
set -uo pipefail

die()  { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }
step() { echo; echo "== $* =="; }

# ---- config / defaults -------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
ENDPOINT="${ENDPOINT:-https://devcms.flawkai.com/api/router/guests}"
DRY_RUN="${DRY_RUN:-false}"
REPO_URL="${REPO_URL:-https://github.com/Jeykobz/tmp_epicenter_captive_portal.git}"
BRANCH="${BRANCH:-main}"
TARBALL="${TARBALL:-https://github.com/Jeykobz/tmp_epicenter_captive_portal/archive/refs/heads/${BRANCH}.tar.gz}"

FLAWK5G=/FlawkDetection/Flawk-5G
NDS_SRC_DIR="$FLAWK5G/nodogsplash"
HTDOCS=/etc/nodogsplash/htdocs
BIN=/usr/bin/nodogsplash
DEVCFG=/FlawkDetection/configuration.json
LOG=/FlawkDetection/Logging/flawk_logging.log
PATCHED_FILES="auth.c auth.h http_microhttpd.c ndsctl_thread.c"

WORK=""; BUILD=""; PLACE_ID=""; APIKEY=""; GOT=""
cleanup() { rm -rf "$WORK" "$BUILD" 2>/dev/null || true; }
trap cleanup EXIT

listens_2050() { (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ':2050'; }
healthy() { systemctl is-active --quiet nodogsplash && listens_2050; }
wait_healthy() { local i; for i in 1 2 3 4 5; do sleep 2; healthy && return 0; done; return 1; }

# ---- 0. root + arg sanity ----------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash /tmp/install.sh"
case "$DRY_RUN" in true|false) ;; *) die "DRY_RUN must be 'true' or 'false' (got '$DRY_RUN')";; esac
# Crontab owner: the package keeps its cron under the login user; the lines self-sudo.
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || TARGET_USER="$(logname 2>/dev/null || true)"
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || TARGET_USER="$(stat -c %U "$FLAWK5G" 2>/dev/null || echo pi)"

# ---- 1. pre-flight (abort before touching anything) --------------------------
step "1. Pre-flight"
[ -d /etc/nodogsplash ]        || die "/etc/nodogsplash missing -- nodogsplash is not installed here."
[ -d "$NDS_SRC_DIR" ]          || die "$NDS_SRC_DIR missing -- this is not a Flawk-5G device."
[ -f "$NDS_SRC_DIR/Makefile" ] || die "nodogsplash Makefile missing at $NDS_SRC_DIR."
if grep -qE '^[[:space:]]*(WebRoot|SplashPage)' /etc/nodogsplash/nodogsplash.conf 2>/dev/null; then
  die "WebRoot/SplashPage is overridden in nodogsplash.conf; served payload may not be $HTDOCS. Resolve manually."
fi
for t in gcc make python3; do command -v "$t" >/dev/null 2>&1 || die "$t not found (needed to build/verify)."; done
if ! { [ -f /usr/include/microhttpd.h ] || ldconfig -p 2>/dev/null | grep -qi microhttpd \
       || dpkg -s libmicrohttpd-dev >/dev/null 2>&1; }; then
  die "libmicrohttpd dev files not found -- cannot build nodogsplash (apt install libmicrohttpd-dev)."
fi
command -v git >/dev/null 2>&1 || { command -v wget >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; } \
  || die "need 'git', or 'wget'+'tar', to fetch the payload."
if [ -f "$DEVCFG" ]; then
  PLACE_ID=$(python3 -c "import json,sys;print(json.load(open('$DEVCFG')).get('place_id',''))" 2>/dev/null || true)
  APIKEY=$(python3 -c "import json,sys;print(json.load(open('$DEVCFG')).get('api_key',''))" 2>/dev/null || true)
  [ -n "$APIKEY" ] || note "WARNING: configuration.json has no api_key -- forwarder will skip until it is set."
else
  note "WARNING: $DEVCFG missing -- forwarder will skip until it exists."
fi
note "pre-flight OK (crontab user: $TARGET_USER)"

# ---- 2. fetch + verify payload ----------------------------------------------
step "2. Fetch payload"
WORK=$(mktemp -d /tmp/epicenter-install.XXXXXX) || die "mktemp failed"
SRC=""
if command -v git >/dev/null 2>&1 && git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$WORK/repo" >/dev/null 2>&1; then
  SRC="$WORK/repo"
else
  note "git clone unavailable/failed -- falling back to tarball"
  ( cd "$WORK" && wget -qO - "$TARBALL" | tar xz ) || die "tarball fetch failed."
  SRC=$(find "$WORK" -maxdepth 1 -type d -name 'tmp_epicenter_captive_portal-*' | head -1)
  [ -n "$SRC" ] || die "could not locate extracted payload."
fi
[ -f "$SRC/MD5SUMS" ] && [ -f "$SRC/payload/MD5SUMS" ] || die "payload manifests missing in checkout."
( cd "$SRC"         && md5sum -c MD5SUMS >/dev/null ) || die "theme payload failed md5 verification."
( cd "$SRC/payload" && md5sum -c MD5SUMS >/dev/null ) || die "code payload failed md5 verification."
note "payload fetched + md5-verified"

# ---- 3. backups (single timestamp) ------------------------------------------
step "3. Backup (timestamp $TS)"
cp -a "$BIN" "$BIN.bak.$TS"        || die "could not back up $BIN."
cp -a "$HTDOCS" "${HTDOCS}.bak.$TS" || die "could not back up $HTDOCS."
SRCBK="$NDS_SRC_DIR/src/.bak.$TS"; mkdir -p "$SRCBK"
for f in $PATCHED_FILES; do [ -f "$NDS_SRC_DIR/src/$f" ] && cp -a "$NDS_SRC_DIR/src/$f" "$SRCBK/$f"; done
[ -f "$FLAWK5G/guest_forwarder.py" ] && cp -a "$FLAWK5G/guest_forwarder.py" "$FLAWK5G/guest_forwarder.py.bak.$TS"
crontab -u "$TARGET_USER" -l > "$WORK/crontab.$TS" 2>/dev/null || true
note "binary -> $BIN.bak.$TS ; htdocs -> ${HTDOCS}.bak.$TS ; sources -> $SRCBK"

# ---- 4. build in a throwaway copy (device source stays pristine on failure) --
step "4. Build patched nodogsplash (in /tmp)"
BUILD="/tmp/nds-build.$TS"; rm -rf "$BUILD"
cp -a "$NDS_SRC_DIR" "$BUILD" || die "could not copy nodogsplash source for build."
for f in $PATCHED_FILES; do
  cp "$SRC/payload/nodogsplash-src/$f" "$BUILD/src/$f" || die "could not stage patched $f."
done
( cd "$BUILD" && make clean >/dev/null 2>&1; make ) > "$WORK/build.log" 2>&1
if [ ! -x "$BUILD/nodogsplash" ]; then
  echo "---- build log (tail) ----"; tail -n 30 "$WORK/build.log"
  die "build produced no nodogsplash binary. Nothing on the device was changed."
fi
file "$BUILD/nodogsplash" 2>/dev/null | grep -q 'ELF' || die "built artifact is not an ELF binary."
BSIZE=$(stat -c %s "$BUILD/nodogsplash" 2>/dev/null || echo 0)
[ "$BSIZE" -gt 100000 ] || die "built binary implausibly small ($BSIZE bytes)."
note "built OK ($BSIZE bytes)"

# ---- 5. swap the live binary behind a runtime health gate -------------------
step "5. Install binary (health-gated)"
systemctl stop nodogsplash >/dev/null 2>&1; sleep 1   # avoid 'Text file busy' on a running binary
if ! cp "$BUILD/nodogsplash" "$BIN"; then
  cp -a "$BIN.bak.$TS" "$BIN"; systemctl start nodogsplash >/dev/null 2>&1
  die "could not write new binary; restored original."
fi
chmod 755 "$BIN"
systemctl start nodogsplash >/dev/null 2>&1
if wait_healthy; then
  note "nodogsplash active + listening on :2050 with the patched binary"
else
  note "patched binary did NOT come up healthy -- ROLLING BACK"
  systemctl stop nodogsplash >/dev/null 2>&1; sleep 1
  cp -a "$BIN.bak.$TS" "$BIN"; systemctl start nodogsplash >/dev/null 2>&1
  if wait_healthy; then
    die "patched binary failed the health check; ORIGINAL restored and healthy. No change kept."
  fi
  die "patched binary failed AND rollback unhealthy. Restore manually: sudo cp -a $BIN.bak.$TS $BIN; sudo systemctl restart nodogsplash"
fi

# ---- 6. consent-fixed Epicenter splash --------------------------------------
step "6. Apply consent-fixed Epicenter splash"
mkdir -p "$HTDOCS/images"
cp "$SRC/splash.html" "$HTDOCS/splash.html"
cp "$SRC/status.html" "$HTDOCS/status.html"
cp "$SRC/images/epicenter.png" "$HTDOCS/images/epicenter.png"
chown root:root "$HTDOCS/splash.html" "$HTDOCS/status.html" "$HTDOCS/images/epicenter.png"
chmod 644       "$HTDOCS/splash.html" "$HTDOCS/status.html" "$HTDOCS/images/epicenter.png"
WANT=$(md5sum "$SRC/splash.html" | cut -d' ' -f1)
GOT=$(md5sum "$HTDOCS/splash.html" | cut -d' ' -f1)
[ "$WANT" = "$GOT" ] || die "live splash md5 mismatch after copy ($GOT != $WANT)."
note "live splash md5 $GOT (consent-fixed: sms_on optional, terms required+named)"

# ---- 7. forwarder + config ---------------------------------------------------
step "7. Install guest forwarder + config"
cp "$SRC/payload/guest_forwarder.py" "$FLAWK5G/guest_forwarder.py"
chmod 755 "$FLAWK5G/guest_forwarder.py"
if ! python3 -m py_compile "$FLAWK5G/guest_forwarder.py"; then
  [ -f "$FLAWK5G/guest_forwarder.py.bak.$TS" ] && cp -a "$FLAWK5G/guest_forwarder.py.bak.$TS" "$FLAWK5G/guest_forwarder.py"
  die "guest_forwarder.py failed py_compile; restored previous copy."
fi
CFG="$FLAWK5G/guest_forwarder_config.json"
printf '{\n  "enabled": true,\n  "dry_run": %s,\n  "endpoint": "%s"\n}\n' "$DRY_RUN" "$ENDPOINT" > "$CFG"
chmod 600 "$CFG"
python3 -c "import json;json.load(open('$CFG'))" || die "generated config is not valid JSON."
note "forwarder installed; config endpoint=$ENDPOINT dry_run=$DRY_RUN"

# ---- 8. schedule (idempotent 30s cron pair) ---------------------------------
step "8. Schedule forwarder (30s cron pair)"
CUR=$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)
if printf '%s\n' "$CUR" | grep -q 'guest_forwarder.py'; then
  note "cron already contains guest_forwarder -- left as-is"
else
  { printf '%s\n' "$CUR"
    echo '* * * * * sudo python3 /FlawkDetection/Flawk-5G/guest_forwarder.py'
    echo '* * * * * ( sleep 30 ; sudo python3 /FlawkDetection/Flawk-5G/guest_forwarder.py )'
  } | crontab -u "$TARGET_USER" - || die "could not install cron for user $TARGET_USER."
  note "installed 30s cron pair for user $TARGET_USER"
fi

# ---- 9. sync device source + self-verify ------------------------------------
step "9. Sync device source + self-verify"
for f in $PATCHED_FILES; do
  cp "$SRC/payload/nodogsplash-src/$f" "$NDS_SRC_DIR/src/$f" 2>/dev/null || note "WARNING: could not sync src/$f (non-fatal)."
done
# One forwarder run as root (matches the cron's 'sudo python3'): empty spool = safe no-op,
# else it delivers pending rows. Never fatal to the install.
FW=$(python3 "$FLAWK5G/guest_forwarder.py" 2>&1; echo "exit=$?")
note "forwarder self-run: $(printf '%s\n' "$FW" | tail -1)"
if [ -f "$LOG" ]; then echo "  recent log:"; tail -n 4 "$LOG" 2>/dev/null | sed 's/^/    /'; fi

# ---- result ------------------------------------------------------------------
MASK="(none)"; [ -n "$APIKEY" ] && MASK="****${APIKEY: -4}"
CRON_N=$(crontab -u "$TARGET_USER" -l 2>/dev/null | grep -c 'guest_forwarder.py' || echo 0)
echo
echo "================ RESULT ================"
healthy      && echo "  [OK] nodogsplash active + listening on :2050" || echo "  [!!] nodogsplash NOT healthy"
echo "  [OK] live splash md5 $GOT (consent-fixed Epicenter)"
echo "  [OK] forwarder config: endpoint=$ENDPOINT dry_run=$DRY_RUN"
echo "  [OK] cron guest_forwarder lines: $CRON_N"
echo "  device place_id=${PLACE_ID:-?}  api_key=$MASK"
echo
echo "  NOTE: delivery to $ENDPOINT succeeds only if this device's api_key ($MASK)"
echo "        exists in that CMS's users.live_api_key. If not, POSTs 401 and retry --"
echo "        guests are still captured + spooled and the captive portal is unaffected."
echo
echo "  Rollback:"
echo "    sudo systemctl stop nodogsplash"
echo "    sudo cp -a $BIN.bak.$TS $BIN"
echo "    sudo cp -a ${HTDOCS}.bak.$TS/. $HTDOCS/"
echo "    sudo systemctl start nodogsplash"
echo "======================================="
echo
echo "SUCCESS - patch-supported captive portal installed."
