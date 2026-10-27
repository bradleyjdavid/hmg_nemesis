#!/system/bin/sh
# Off-unit safety archive, written to NEMESIS-backup-<time>/ on the stick:
# the live files NEMESIS and its packages change, the package snapshots in
# /data/nemesis/backup, persist.* properties, and a raw image of /system.
# Read-only on the unit. It never restores anything; see RESTORE.txt on the stick.
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

TOAST_ACTION=com.hkmc.intent.action.TOAST
TOAST_MSG_EXTRA=com.hkmc.intent.extra.TOAST_MESSAGE
TOAST_POPUP_EXTRA=com.hkmc.intent.extra.TOAST_POPUPSHOWING
SYSTEM_BLK=/dev/block/platform/bdm/by-name/system

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
OUT="$BASE/NEMESIS-backup-$TS"

if ! mkdir -p "$OUT/files"; then
    toast "Backup: cannot write to USB."
    exit 1
fi
LOG="$OUT/00-log.txt"
MANIFEST="$OUT/00-manifest.txt"
FAILS=0

log() {
    echo "$*" >> "$LOG"
}

# save <path>: copy one live file to files/<path>, record mode/owner and md5.
# VFAT drops ownership and mode, so the manifest keeps them for a restore.
save() {
    _src="$1"
    if [ ! -f "$_src" ]; then
        log "absent $_src"
        echo "ABSENT  $_src" >> "$MANIFEST"
        return 0
    fi
    _dst="$OUT/files$_src"
    mkdir -p "${_dst%/*}" || { log "FAIL mkdir ${_dst%/*}"; FAILS=$((FAILS + 1)); return 1; }
    if ! cat "$_src" > "$_dst"; then
        log "FAIL copy $_src"
        FAILS=$((FAILS + 1))
        return 1
    fi
    echo "$(ls -l "$_src" 2>/dev/null)" >> "$MANIFEST"
    echo "md5 $(md5 "$_src" 2>/dev/null)" >> "$MANIFEST"
    log "saved $_src"
}

# save_tree <dir>: every regular file under <dir>, one level of subdirectories.
save_tree() {
    [ -d "$1" ] || { log "absent $1"; return 0; }
    for _p in "$1"/* "$1"/*/*; do
        [ -f "$_p" ] && save "$_p"
    done
}

toast "Backup started, keep the USB in. This can take several minutes."
log "NEMESIS safety archive $TS"
log "build: $(getprop ro.build.display.id 2>/dev/null)"

# NEMESIS boot hooks: qb_runtime.sh gets a NEMESIS_QB_HOOK block appended;
# install-recovery.sh does not exist on stock.
save /system/etc/qb_runtime.sh
save /system/etc/install-recovery.sh
save /system/build.prop

# adb.tcp
save /system/etc/permissions/com.hkmc.software.engineermode.adb_hide.xml

# wireless.projection
save_tree /system/etc/permissions
save /system/etc/wifi/wpa_supplicant.conf
save /system/etc/wifi/wpa_supplicant_overlay.conf
for _f in /system/onebin/*/featurexml.cfg; do
    [ -f "$_f" ] && save "$_f"
done

# projection.tbt
for _n in HKMC_GPM HKMC_DiPO Iap2ServerApp HKMC_Navi_ExSL; do
    save "/system/app/$_n.apk"
    save "/system/app/$_n.odex"
done
save /system/lib/libautoreceiver_infobank.so

# On-unit package snapshots: `nemesis wipe` deletes these even if a restore failed.
save_tree /data/nemesis/backup
save_tree /data/property

/system/xbin/nemesis pkg-list > "$OUT/nemesis-pkg-list.txt" 2>&1
ls -l /dev/block/platform/bdm/by-name > "$OUT/by-name.txt" 2>&1

# Raw /system image. Reflects /system as it is now, NEMESIS files included.
if [ -b "$SYSTEM_BLK" ]; then
    toast "Backup: imaging /system..."
    if dd if="$SYSTEM_BLK" of="$OUT/system.img" bs=1048576 2>> "$LOG"; then
        echo "md5 $(md5 "$OUT/system.img" 2>/dev/null)" >> "$MANIFEST"
        log "imaged $SYSTEM_BLK"
    else
        rm -f "$OUT/system.img"
        log "FAIL image $SYSTEM_BLK (stick full or read error)"
        FAILS=$((FAILS + 1))
    fi
else
    log "absent $SYSTEM_BLK, no image"
    FAILS=$((FAILS + 1))
fi

cat > "$OUT/RESTORE.txt" << 'EOF'
NEMESIS safety archive.

files/       live copies, at their original paths (files/system/etc/... = /system/etc/...)
00-manifest  ls -l (mode, owner) and md5 of each file at backup time; ABSENT = did not exist
system.img   raw ext4 image of the system partition (open on a PC with debugfs or a loop mount)
00-log.txt   what was saved and any FAIL lines

This script does not restore anything. Restore one file at a time with
`nemesis remount rw`, cat it back, then set mode/owner from the manifest.
Writing system.img back to the partition is a last resort and can brick the
head unit if the image or partition is wrong.

May contain serial numbers and Wi-Fi settings. Keep it private.
EOF

sync
if [ "$FAILS" -ne 0 ]; then
    toast "Backup finished with $FAILS problem(s), see 00-log.txt on USB."
    exit 1
fi
toast "Backup done: NEMESIS-backup-$TS on USB."
exit 0
