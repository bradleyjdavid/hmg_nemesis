#!/system/bin/sh
# Compare the live unit with the newest NEMESIS-backup-*/ archive on the stick
# (made by examples/usb-stick-backup) and write NEMESIS-verify-<time>.txt.
# Read-only. Run it after uninstalling packages and before `nemesis wipe`:
# once wipe has run, no USB script can start.
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

TOAST_ACTION=com.hkmc.intent.action.TOAST
TOAST_MSG_EXTRA=com.hkmc.intent.extra.TOAST_MESSAGE
TOAST_POPUP_EXTRA=com.hkmc.intent.extra.TOAST_POPUPSHOWING

toast() {
    am broadcast -a "$TOAST_ACTION" -e "$TOAST_MSG_EXTRA" "$1" \
        --ez "$TOAST_POPUP_EXTRA" true >/dev/null 2>&1 || true
}

BASE=$(pwd)
if [ ! -d "$BASE" ] || [ "$BASE" = "/" ]; then
    BASE=/storage/usb0
fi
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null)
[ -n "$TS" ] || TS=run
REPORT="$BASE/NEMESIS-verify-$TS.txt"

# Archive names carry a sortable time, so the last match is the newest.
ARCHIVE=""
for _d in "$BASE"/NEMESIS-backup-*; do
    [ -f "$_d/00-manifest.txt" ] && ARCHIVE="$_d"
done
if [ -z "$ARCHIVE" ]; then
    toast "Verify: no NEMESIS-backup archive on USB."
    exit 1
fi
MANIFEST="$ARCHIVE/00-manifest.txt"

if ! : > "$REPORT"; then
    toast "Verify: cannot write to USB."
    exit 1
fi

OK=0
BAD=0
report() {
    echo "$*" >> "$REPORT"
}

# live_md5 <path>: first field of toolbox md5 output, empty if unreadable.
live_md5() {
    set -- $(md5 "$1" 2>/dev/null)
    echo "$1"
}

toast "Verify started, keep the USB in."
report "NEMESIS verify $TS"
report "archive: ${ARCHIVE##*/}"
report "build now: $(getprop ro.build.display.id 2>/dev/null)"
report ""

# Manifest lines, in order:
#   ABSENT  <path>              did not exist at backup time
#   <ls -l line>                mode/owner of the next md5 line's file
#   md5 <hash>  <path>
_mode=""
_owner=""
_group=""
while read -r _a _b _c _rest; do
    case "$_a" in
        ABSENT)
            case "$_b" in /data/nemesis/*) continue ;; esac
            if [ -e "$_b" ]; then
                report "EXTRA    $_b (absent at backup, present now)"
                BAD=$((BAD + 1))
            else
                OK=$((OK + 1))
            fi
            ;;
        md5)
            _want="$_b"
            _p="$_c"
            # NEMESIS's own state and the archive's image are not stock files.
            case "$_p" in
                /data/nemesis/*|"$BASE"/*|*/system.img) _mode=""; continue ;;
            esac
            if [ ! -f "$_p" ]; then
                report "MISSING  $_p"
                BAD=$((BAD + 1))
            else
                _got=$(live_md5 "$_p")
                if [ "$_got" != "$_want" ]; then
                    report "CHANGED  $_p (md5 $_got, backup $_want)"
                    BAD=$((BAD + 1))
                elif [ -n "$_mode" ]; then
                    set -- $(ls -l "$_p" 2>/dev/null)
                    if [ "$1" != "$_mode" ] || [ "$2" != "$_owner" ] || [ "$3" != "$_group" ]; then
                        report "PERMS    $_p ($1 $2 $3, backup $_mode $_owner $_group)"
                        BAD=$((BAD + 1))
                    else
                        OK=$((OK + 1))
                    fi
                else
                    OK=$((OK + 1))
                fi
            fi
            _mode=""
            ;;
        -*)
            _mode="$_a"
            _owner="$_b"
            _group="$_c"
            ;;
    esac
done < "$MANIFEST"

report ""
report "ok=$OK problems=$BAD"
if [ "$BAD" -eq 0 ]; then
    report "All archived files match. Safe to run: nemesis wipe --confirm"
else
    report "Do not wipe yet: the lines above are not back to their backed-up state."
fi
sync

if [ "$BAD" -ne 0 ]; then
    toast "Verify: $BAD problem(s), see NEMESIS-verify-$TS.txt. Do not wipe."
    exit 1
fi
toast "Verify: all $OK files match the backup."
exit 0
