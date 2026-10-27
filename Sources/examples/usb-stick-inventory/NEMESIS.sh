#!/system/bin/sh
# Read-only inventory of the head unit, written to NEMESIS-inventory-<time>/ on the stick.
# Nothing on the unit is changed: no remount, no setprop, no writes outside the stick.
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib

TOAST_ACTION=com.hkmc.intent.action.TOAST
TOAST_MSG_EXTRA=com.hkmc.intent.extra.TOAST_MESSAGE
TOAST_POPUP_EXTRA=com.hkmc.intent.extra.TOAST_POPUPSHOWING

toast() {
    am broadcast -a "$TOAST_ACTION" -e "$TOAST_MSG_EXTRA" "$1" \
        --ez "$TOAST_POPUP_EXTRA" true >/dev/null 2>&1 || true
}

# cwd is the USB root when run from NEMESIS.data; Manager's menu runs it from elsewhere.
BASE=$(pwd)
if [ ! -d "$BASE" ] || [ "$BASE" = "/" ]; then
    BASE=/storage/usb0
fi
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null)
[ -n "$TS" ] || TS=run
OUT="$BASE/NEMESIS-inventory-$TS"

if ! mkdir -p "$OUT"; then
    toast "Inventory: cannot write to USB."
    exit 1
fi
INDEX="$OUT/00-index.txt"

# run <file> <cmd...>: output and exit code of one command into its own file.
run() {
    _f="$OUT/$1"
    shift
    echo "\$ $*" > "$_f"
    "$@" >> "$_f" 2>&1
    _rc=$?
    echo "rc=$_rc" >> "$_f"
    echo "$_rc  ${_f##*/}  $*" >> "$INDEX"
}

# copy_dir <src-dir> <dest-subdir>: cat each regular file (VFAT-safe, no cp -r).
copy_dir() {
    _src="$1"
    _dst="$OUT/$2"
    [ -d "$_src" ] || return 0
    mkdir -p "$_dst" || return 0
    for _p in "$_src"/*; do
        [ -f "$_p" ] || continue
        cat "$_p" > "$_dst/${_p##*/}" 2>/dev/null
    done
    echo "-  $2/  copied from $_src" >> "$INDEX"
}

toast "Inventory started, keep the USB in."

cat > "$OUT/00-README.txt" << 'EOF'
NEMESIS head unit inventory (read-only).

May contain identifiers (serial numbers in getprop/build.prop, account or
device names in dumpsys output). Review before sharing publicly.

00-index.txt lists every file with the command's exit code (first column).
EOF

# Identity and build
run build.prop.txt cat /system/build.prop
run getprop.txt getprop
run proc-version.txt cat /proc/version
run cpuinfo.txt cat /proc/cpuinfo
run meminfo.txt cat /proc/meminfo
run mounts.txt cat /proc/mounts
run partitions.txt cat /proc/partitions
run df.txt df
run input-devices.txt cat /proc/bus/input/devices

# Apps, components, features
run pm-packages.txt pm list packages -f -i
run pm-packages-disabled.txt pm list packages -d
run pm-features.txt pm list features
run pm-libraries.txt pm list libraries
run pm-permissions.txt pm list permissions -g -f
run pm-instrumentation.txt pm list instrumentation
run dumpsys-package.txt dumpsys package

# Running system
run service-list.txt service list
run dumpsys-activity-services.txt dumpsys activity services
run dumpsys-activity-broadcasts.txt dumpsys activity broadcasts
run dumpsys-activity-providers.txt dumpsys activity providers
run ps.txt ps

# Files on /system, init services, feature XMLs
run ls-system.txt ls -lR /system
run ls-vendor.txt ls -lR /vendor
run ls-root.txt ls -l /
run ls-dev.txt ls -l /dev
copy_dir /system/etc/permissions etc-permissions
mkdir -p "$OUT/init-rc"
for _rc in /init*.rc; do
    [ -f "$_rc" ] && cat "$_rc" > "$OUT/init-rc/${_rc##*/}" 2>/dev/null
done
echo "-  init-rc/  copied from /init*.rc" >> "$INDEX"

# NEMESIS state
run nemesis-pkg-list.txt /system/xbin/nemesis pkg-list
run nemesis-service-list.txt /system/xbin/nemesis service list

sync
toast "Inventory done: NEMESIS-inventory-$TS on USB."
exit 0
