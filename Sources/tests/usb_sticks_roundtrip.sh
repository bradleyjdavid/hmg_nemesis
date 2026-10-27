#!/bin/bash
# Host round trip for examples/usb-stick-backup and examples/usb-stick-verify.
# Both scripts are run under mksh with /system and /data rewritten into a fake
# tree, and with stubs for the toolbox commands the host does not have.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_SH=$(command -v mksh || command -v bash)
WORK=$(mktemp -d /tmp/nemesis-sticks.XXXXXX)
F=$WORK/fake
USB=$WORK/usb
STUBS=$WORK/stubs

cleanup() {
    case "${WORK:-}" in
        /tmp/nemesis-sticks.*) rm -rf "$WORK" ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

mkdir -p "$USB" "$STUBS" "$F/system/etc/permissions" "$F/system/etc/wifi" \
    "$F/system/app" "$F/system/lib" "$F/system/onebin/cvev_us" \
    "$F/data/nemesis/backup/adb.tcp" "$F/data/property"
echo "stock qb" > "$F/system/etc/qb_runtime.sh"
echo "ro.adb.secure=1" > "$F/system/build.prop"
echo "<hide/>" > "$F/system/etc/permissions/com.hkmc.software.engineermode.adb_hide.xml"
echo "<wifi/>" > "$F/system/etc/permissions/android.hardware.wifi.xml"
echo "network={}" > "$F/system/etc/wifi/wpa_supplicant.conf"
echo "carplay_wireless=0" > "$F/system/onebin/cvev_us/featurexml.cfg"
echo apk > "$F/system/app/HKMC_GPM.apk"
echo odex > "$F/system/app/HKMC_GPM.odex"
echo lib > "$F/system/lib/libautoreceiver_infobank.so"
echo 1 > "$F/data/nemesis/backup/adb.tcp/saved"
echo 1 > "$F/data/property/persist.service.adb.tcp.enable"

# Toolbox stand-ins: md5 prints "<hash>  <path>"; ls -l on a file has no
# link-count column; am and getprop are not needed for the result. The stick
# scripts run with a reduced PATH, so stubs call tools by absolute path.
for c in am getprop; do
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/$c"
done
if MD5SUM=$(command -v md5sum); then
    printf '#!/bin/sh\nexec %s "$1"\n' "$MD5SUM" > "$STUBS/md5"
else
    printf '#!/bin/sh\nexec /sbin/md5 -r "$1"\n' > "$STUBS/md5"
fi
cat > "$STUBS/ls" <<'EOF'
#!/bin/sh
if [ "$1" = -l ] && [ -f "$2" ]; then
    /bin/ls -l "$2" | sed -E 's/^([^ ]+) +[0-9]+ /\1 /'
else
    exec /bin/ls "$@"
fi
EOF
chmod +x "$STUBS"/*

for n in backup verify; do
    sed -e "s#^export PATH=.*#export PATH=$STUBS:/usr/bin:/bin#" \
        -e "s#/system/#$F/system/#g" -e "s#/data/#$F/data/#g" \
        "$ROOT/examples/usb-stick-$n/NEMESIS.sh" > "$WORK/$n.sh"
done

# run_stick <name> <expected-rc>: run from the stick root, as the handler does.
run_stick() {
    local rc=0
    ( cd "$USB" && "$DEV_SH" "$WORK/$1.sh" ) >"$WORK/$1.out" 2>&1 || rc=$?
    if [ "$rc" -ne "$2" ]; then
        cat "$WORK/$1.out"
        fail "$1 stick returned $rc, want $2"
    fi
}

latest() {
    local last=""
    for p in "$USB"/$1; do
        [ -e "$p" ] && last=$p
    done
    [ -n "$last" ] || fail "no $1 on the stick"
    echo "$last"
}

# Verify with no archive refuses to report.
run_stick verify 1

# Backup: everything is saved; only the raw image is missing on a host.
run_stick backup 1
ARCHIVE=$(latest 'NEMESIS-backup-*')
grep -q "no image" "$ARCHIVE/00-log.txt" || fail "backup did not report the missing image"
if grep -v "no image" "$ARCHIVE/00-log.txt" | grep -q FAIL; then
    cat "$ARCHIVE/00-log.txt"
    fail "backup logged a failure other than the image"
fi
for f in system/build.prop system/etc/qb_runtime.sh system/app/HKMC_GPM.apk \
        system/onebin/cvev_us/featurexml.cfg data/nemesis/backup/adb.tcp/saved; do
    cmp -s "$F/$f" "$ARCHIVE/files$F/$f" || fail "archive copy of $f differs"
done
grep -q "^ABSENT  $F/system/etc/install-recovery.sh" "$ARCHIVE/00-manifest.txt" ||
    fail "manifest does not record install-recovery.sh as absent"
echo "ok: backup copies the changed files and records absent ones"

# Verify against an untouched unit.
run_stick verify 0
REPORT=$(latest 'NEMESIS-verify-*.txt')
grep -q "problems=0" "$REPORT" || { cat "$REPORT"; fail "clean unit did not verify"; }
echo "ok: verify passes on an untouched unit"

# A bad restore: changed bytes, wrong mode, missing file, extra file. The
# on-unit package snapshot going away is expected after uninstall.
echo "ro.adb.secure=0" > "$F/system/build.prop"
chmod 600 "$F/system/etc/wifi/wpa_supplicant.conf"
rm "$F/system/app/HKMC_GPM.apk"
echo x > "$F/system/etc/install-recovery.sh"
rm -rf "$F/data/nemesis/backup"
run_stick verify 1
REPORT=$(latest 'NEMESIS-verify-*.txt')
grep -q "^CHANGED  $F/system/build.prop" "$REPORT" || fail "no CHANGED for build.prop"
grep -q "^PERMS    $F/system/etc/wifi/wpa_supplicant.conf" "$REPORT" || fail "no PERMS for wpa_supplicant.conf"
grep -q "^MISSING  $F/system/app/HKMC_GPM.apk" "$REPORT" || fail "no MISSING for HKMC_GPM.apk"
grep -q "^EXTRA    $F/system/etc/install-recovery.sh" "$REPORT" || fail "no EXTRA for install-recovery.sh"
if grep -q "/data/nemesis/" "$REPORT"; then
    cat "$REPORT"
    fail "verify reported NEMESIS's own snapshots"
fi
grep -q "problems=4" "$REPORT" || { cat "$REPORT"; fail "expected exactly 4 problems"; }
echo "ok: verify reports CHANGED, PERMS, MISSING and EXTRA"

echo "ALL USB STICK ROUND TRIP TESTS PASSED"
