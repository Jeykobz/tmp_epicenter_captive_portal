#!/bin/bash
# Move a Flawk-5G access point from 5 GHz ch36 to 2.4 GHz, and set a real regulatory
# domain. Fixes guests whose phones cannot join at all (e.g. iPhone 12 fails while
# iPhone 15 works): in regdomain "00" the 5 GHz band is passive-scan / no-initiating-
# radiation and beacons carry no Country IE, which clients enforce inconsistently by
# baseband generation. 2.4 GHz also has materially better range.
#
#   wget -qO /tmp/fix_ap.sh https://raw.githubusercontent.com/Jeykobz/tmp_epicenter_captive_portal/main/fix_ap_24ghz.sh
#   sudo bash /tmp/fix_ap.sh
#
# Idempotent. Auto-detects this device's interface and connection name. Verifies the AP
# actually comes back up and AUTO-ROLLS-BACK if it does not. Does not reboot.
#
# Env overrides:  CHANNEL=1|6|11 (default: auto-survey)   REGDOM=US   FORCE=1 (ignore connected clients)

set -uo pipefail

AP_SH=${AP_SH:-/FlawkDetection/Flawk-5G/AP.sh}
REGDOM=${REGDOM:-US}
CHANNEL=${CHANNEL:-auto}
FORCE=${FORCE:-0}

die()  { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo."
command -v nmcli >/dev/null || die "nmcli not found."
command -v iw    >/dev/null || die "iw not found."
[ -f "$AP_SH" ]             || die "$AP_SH not found - is this a Flawk-5G device?"

echo "== 1. Detect this device's AP =="
CON=$(grep -oP 'con-name\s+"\K[^"]+' "$AP_SH" | head -1)
[ -n "$CON" ] || CON=$(grep -oP 'con-name\s+\K[^ ]+' "$AP_SH" | head -1)
IFACE=$(grep -oP 'ifname\s+\K[^ ]+' "$AP_SH" | head -1)
[ -n "$CON" ]   || die "could not parse con-name from $AP_SH"
[ -n "$IFACE" ] || die "could not parse ifname from $AP_SH"
[ -d "/sys/class/net/$IFACE" ] || die "interface $IFACE does not exist on this device."
nmcli -t -f NAME con show 2>/dev/null | grep -qxF "$CON" || die "NM connection '$CON' not found."
note "connection : $CON"
note "interface  : $IFACE"

ORIG_BAND=$(nmcli -g 802-11-wireless.band con show "$CON" 2>/dev/null)
ORIG_CHAN=$(nmcli -g 802-11-wireless.channel con show "$CON" 2>/dev/null)
note "current    : band=${ORIG_BAND:-unset} channel=${ORIG_CHAN:-unset}"

if [ "$ORIG_BAND" = "bg" ]; then
  echo
  echo "Already on 2.4 GHz (band=bg, channel=$ORIG_CHAN). Re-verifying only."
  iw reg get 2>/dev/null | grep -q "country $REGDOM" || { iw reg set "$REGDOM"; note "regdomain re-applied: $REGDOM"; }
  grep -q 'iw reg set' "$AP_SH" || note "WARNING: $AP_SH has no 'iw reg set' - regdomain will reset on reboot"
  iw dev "$IFACE" info 2>/dev/null | grep -E 'ssid|type|channel'
  exit 0
fi

echo "== 2. Safety checks =="
STATIONS=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
note "clients currently connected: $STATIONS"
if [ "$STATIONS" -gt 0 ] && [ "$FORCE" != "1" ]; then
  die "$STATIONS client(s) connected; they would be disconnected. Re-run with FORCE=1 to proceed anyway."
fi

echo "== 3. Choose channel =="
if [ "$CHANNEL" = "auto" ]; then
  nmcli dev wifi rescan >/dev/null 2>&1
  sleep 8
  # 20 MHz channels overlap within +/-4, so score 1/6/11 by neighbours in that span.
  CHANNEL=$(nmcli -t -f CHAN,SIGNAL dev wifi list 2>/dev/null | awk -F: '
    $1+0>=1 && $1+0<=14 { ch[NR]=$1+0; sg[NR]=$2+0; n++ }
    END {
      best=11; bestc=999; bests=999
      split("1 6 11", cand, " ")
      for (i in cand) { c=cand[i]+0; cnt=0; mx=0
        for (j in ch) if ((ch[j]-c)<=4 && (c-ch[j])<=4) { cnt++; if (sg[j]>mx) mx=sg[j] }
        if (cnt<bestc || (cnt==bestc && mx<bests)) { best=c; bestc=cnt; bests=mx }
      }
      print best
    }')
  [ -n "$CHANNEL" ] || CHANNEL=11
  note "survey picked channel $CHANNEL"
else
  note "channel $CHANNEL (from CHANNEL env)"
fi
case "$CHANNEL" in 1|6|11) ;; *) die "channel '$CHANNEL' is not one of 1/6/11." ;; esac

echo "== 4. Backup =="
BK="$AP_SH.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$AP_SH" "$BK" || die "backup failed"
note "backup: $BK"

echo "== 5. Regulatory domain =="
iw reg set "$REGDOM" || die "iw reg set $REGDOM failed"
sleep 2
iw reg get 2>/dev/null | grep -q "country $REGDOM" \
  && note "regdomain now $REGDOM" \
  || note "WARNING: regdomain did not report $REGDOM"

echo "== 6. Apply to the live AP =="
# band and channel MUST be set in ONE modify: NM validates each modify independently, so
# 'band bg' is rejected while the channel is still 36, and setting the channel first leaves
# an impossible band/channel pair that fails to activate with a misleading
# "802.1X supplicant took too long to authenticate".
nmcli con modify "$CON" 802-11-wireless.band bg 802-11-wireless.channel "$CHANNEL" \
  || die "could not set band+channel (nothing changed yet)"
nmcli con down "$CON" >/dev/null 2>&1
sleep 2
nmcli con up "$CON" >/dev/null 2>&1
sleep 5

echo "== 7. Gate: did the AP come back? =="
UP=0
iw dev "$IFACE" info 2>/dev/null | grep -q 'type AP' \
  && ip -br addr show "$IFACE" 2>/dev/null | grep -q '10\.42\.0\.1' && UP=1
if [ "$UP" != "1" ]; then
  echo "  AP did NOT come up on 2.4 GHz - ROLLING BACK to band=${ORIG_BAND} channel=${ORIG_CHAN}"
  nmcli con modify "$CON" 802-11-wireless.band "${ORIG_BAND:-a}" 802-11-wireless.channel "${ORIG_CHAN:-36}"
  nmcli con down "$CON" >/dev/null 2>&1; sleep 2; nmcli con up "$CON" >/dev/null 2>&1; sleep 4
  cp -a "$BK" "$AP_SH"
  systemctl restart nodogsplash >/dev/null 2>&1
  iw dev "$IFACE" info 2>/dev/null | grep -E 'type|channel'
  die "2.4 GHz AP mode did not work on this adapter. Rolled back; device left on its original settings."
fi
note "AP up: $(iw dev "$IFACE" info | grep -oP 'channel \K[0-9]+ \([0-9]+ MHz\)')"

echo "== 8. Restart captive portal =="
systemctl restart nodogsplash >/dev/null 2>&1
sleep 4
systemctl is-active --quiet nodogsplash && note "nodogsplash active" || note "WARNING: nodogsplash not active"
ss -tln 2>/dev/null | grep -q ':2050' && note "listening on 2050" || note "WARNING: not listening on 2050"
pgrep -f "dnsmasq.*$IFACE" >/dev/null && note "dnsmasq serving DHCP" || note "WARNING: dnsmasq not running"

echo "== 9. Persist across reboot =="
# start_router.py deletes and recreates the AP from AP.sh on EVERY boot, so the live change
# above reverts without this. Splitting band/channel is safe here (unlike step 6) because
# AP.sh runs 'nmcli con add' first, leaving a fresh profile with no channel set.
# Insert the regdomain line after the shebang. Built with printf rather than `sed 1a\`
# because that construct's backslash-continuation is fragile across quoting layers and
# silently merges the comment and the command onto one line -- which comments out the
# command while still passing both `bash -n` and a naive `grep 'iw reg set'`.
if ! grep -q '^[[:space:]]*iw reg set' "$AP_SH"; then
  _tmp=$(mktemp) || die "mktemp failed"
  {
    head -n 1 "$AP_SH"
    printf '\n# Regulatory domain must be set before the AP starts (resets to 00 each boot).\n'
    printf 'iw reg set %s\n' "$REGDOM"
    tail -n +2 "$AP_SH"
  } > "$_tmp" || die "could not build updated AP.sh"
  cat "$_tmp" > "$AP_SH" && rm -f "$_tmp"    # write through to preserve ownership/mode
fi
sed -i 's/802-11-wireless\.band[[:space:]]\+a\b/802-11-wireless.band bg/' "$AP_SH"
sed -i "s/802-11-wireless\.channel[[:space:]]\+[0-9]\+/802-11-wireless.channel $CHANNEL/" "$AP_SH"

bash -n "$AP_SH" || { cp -a "$BK" "$AP_SH"; die "edited AP.sh failed syntax check; restored backup."; }
grep -q '802-11-wireless.band bg'            "$AP_SH" || { cp -a "$BK" "$AP_SH"; die "band edit did not apply; restored backup."; }
grep -q "802-11-wireless.channel $CHANNEL"   "$AP_SH" || { cp -a "$BK" "$AP_SH"; die "channel edit did not apply; restored backup."; }
# Anchored: an unanchored match would also hit the line inside a comment, which is exactly
# how a commented-out (i.e. dead) regdomain line could pass verification unnoticed.
grep -qE "^[[:space:]]*iw reg set $REGDOM\b" "$AP_SH" || { cp -a "$BK" "$AP_SH"; die "regdomain line not active in AP.sh; restored backup."; }
note "AP.sh updated and syntax-checked"

echo
echo "SUCCESS - $CON is now on 2.4 GHz channel $CHANNEL, regdomain $REGDOM."
echo "Persisted in $AP_SH (backup: $BK)."
echo
echo "Verify after next reboot:"
echo "  iw reg get | head -2                      # country $REGDOM"
echo "  sudo iw dev $IFACE info | grep channel    # channel $CHANNEL"
echo
echo "Tell testers to 'Forget This Network' first, then rejoin."
echo "NOTE: this fixes JOINING the network. Completing the signup form is a separate issue."
echo
echo "Rollback:"
echo "  sudo cp -a $BK $AP_SH"
echo "  sudo nmcli con modify \"$CON\" 802-11-wireless.band ${ORIG_BAND:-a} 802-11-wireless.channel ${ORIG_CHAN:-36}"
echo "  sudo nmcli con down \"$CON\"; sudo nmcli con up \"$CON\"; sudo systemctl restart nodogsplash"
