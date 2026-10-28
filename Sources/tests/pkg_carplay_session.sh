#!/bin/bash
# Host check for carplay.session. The package is pinned to 260507 and must
# not replace an APK when the live odex checksum does not match.
# Requires a user+mount namespace (unshare). Does not touch the host /system.
set -euo pipefail

# Repo root, from this file. Inside the private root the repo is bind-mounted
# at the same path, so this resolves the same there.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=$ROOT/packages/carplay.session
# Stock 260507 apk/ and odex/ directories, extracted from that firmware.
STOCK=${NEMESIS_STOCK_260507:-/mnt/c/Users/gmirz/Downloads/EV6/firmware_260507_projection}

if [ "${NEMESIS_HOOK_NS:-}" != 1 ]; then
    if [ ! -d "$PKG" ]; then
        echo "SKIP: $PKG is not in this tree"
        exit 0
    fi
    if [ ! -d "$STOCK" ]; then
        echo "SKIP: no stock 260507 files at $STOCK; set NEMESIS_STOCK_260507"
        exit 0
    fi
    if ! unshare --user --map-root-user --mount true; then
        echo "FAIL: unshare user+mount namespace is not available"
        exit 1
    fi
    NEMESIS_HOOK_NS=1
    if command -v mksh >/dev/null 2>&1; then
        HOOK_SH=mksh
    else
        HOOK_SH=bash
    fi
    NEMESIS_PYLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
    NEMESIS_ROOTFS=$(mktemp -d /tmp/nemesis-rootfs.XXXXXX)
    NEMESIS_REPO=$ROOT
    NEMESIS_STOCK=$STOCK
    export NEMESIS_HOOK_NS HOOK_SH NEMESIS_PYLIB NEMESIS_ROOTFS NEMESIS_REPO NEMESIS_STOCK
    set +e
    unshare --user --map-root-user --mount bash -c '
        set -euo pipefail
        r="$NEMESIS_ROOTFS/r"
        pylib="$NEMESIS_PYLIB"
        mkdir -p "$r/usr/bin" "$r/usr/lib64" "$r/usr/lib/x86_64-linux-gnu" "$r$pylib" \
            "$r/dev" "$r/system" "$r/data" "$r/tmp" "$r$NEMESIS_REPO" "$r/etc" "$r/opt/stock260507"
        mount --bind /usr/bin "$r/usr/bin"
        mount --bind /usr/lib64 "$r/usr/lib64"
        mount --bind /usr/lib/x86_64-linux-gnu "$r/usr/lib/x86_64-linux-gnu"
        mount --bind "$pylib" "$r$pylib"
        mount --bind "$NEMESIS_REPO" "$r$NEMESIS_REPO"
        mount --bind "$NEMESIS_STOCK" "$r/opt/stock260507"
        for n in null zero urandom random tty; do
            if [ -e "/dev/$n" ]; then
                touch "$r/dev/$n"
                mount --bind "/dev/$n" "$r/dev/$n"
            fi
        done
        ln -s usr/bin "$r/bin"
        ln -s usr/lib64 "$r/lib64"
        ln -s usr/lib "$r/lib"
        if [ -f /etc/ld.so.cache ]; then
            cp /etc/ld.so.cache "$r/etc/ld.so.cache"
        fi
        printf "%s\n" private > "$r/.nemesis-hook-private"
        chroot "$r" /bin/bash "$NEMESIS_REPO/tests/pkg_carplay_session.sh"
    '
    status=$?
    set -e
    case "$NEMESIS_ROOTFS" in
        /tmp/nemesis-rootfs.*) rm -rf "$NEMESIS_ROOTFS" ;;
    esac
    exit "$status"
fi

if [ ! -f /.nemesis-hook-private ]; then
    echo "FAIL: refusing to touch /system outside the private root"
    exit 1
fi

HOOK_SH=${HOOK_SH:-bash}
FAKE=$(mktemp -d /tmp/nemesis-hook.XXXXXX)
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
    case "${FAKE:-}" in
        /tmp/nemesis-hook.*) rm -rf "$FAKE" ;;
    esac
}
trap cleanup EXIT

run_hook() {
    local hook="$1"
    local out="$FAKE/hook.out"
    if ! ( cd "$PKG" && "$HOOK_SH" "./scripts/$hook" ) >"$out" 2>&1; then
        cat "$out" || true
        fail "$hook failed"
    fi
}

link_tool() {
    local src
    src=$(type -P "$1" || true)
    [ -n "$src" ] || fail "host tool missing: $1"
    ln -sf "$src" "/system/bin/$1"
}

mkdir -p /system/bin /system/xbin /data
printf '%s\n' "$FAKE" > /system/HOOKTEST_ROOT
for t in mkdir chmod chown cp rm cat grep ls sync date id printf cmp md5sum; do
    link_tool "$t"
done
printf '%s\n' '#!/bin/sh' 'exit 0' > /system/bin/mount
printf '%s\n' '#!/bin/sh' 'exit 0' > /system/bin/am
printf '%s\n' '#!/bin/sh' 'exit 0' > /system/xbin/nemesis
cat > /system/bin/getprop << 'EOF'
#!/bin/sh
f="/data/property/$1"
if [ -f "$f" ]; then
    cat "$f"
fi
exit 0
EOF
cat > /system/bin/setprop << 'EOF'
#!/bin/sh
mkdir -p /data/property
printf '%s\n' "$2" > "/data/property/$1"
exit 0
EOF
cat > /system/bin/reboot << 'EOF'
#!/bin/sh
mkdir -p /data/nemesis
echo reboot >> /data/nemesis/reboot.log
exit 0
EOF
chmod 755 /system/bin/getprop /system/bin/setprop /system/bin/mount /system/bin/am \
    /system/bin/reboot /system/xbin/nemesis

seed() {
    rm -rf /system/app /system/build.prop /data/nemesis /data/property
    mkdir -p /system/app /data/property /data/nemesis
    cp -a /opt/stock260507/apk/HKMC_DiPO.apk /system/app/HKMC_DiPO.apk
    cp -a /opt/stock260507/odex/HKMC_DiPO.odex /system/app/HKMC_DiPO.odex
    cp -a /opt/stock260507/apk/Iap2ServerApp.apk /system/app/Iap2ServerApp.apk
    cp -a /opt/stock260507/odex/Iap2ServerApp.odex /system/app/Iap2ServerApp.odex
    cp -a /opt/stock260507/apk/Bluetooth.apk /system/app/Bluetooth.apk
    cp -a /opt/stock260507/odex/Bluetooth.odex /system/app/Bluetooth.odex
    printf '%s\n' 'ro.keep=1' 'persist.ium.support=carplay' > /system/build.prop
    cp -a /system/build.prop "$FAKE/bp.orig"
    cp -a /system/app/HKMC_DiPO.apk "$FAKE/dipo.apk"
    cp -a /system/app/HKMC_DiPO.odex "$FAKE/dipo.odex"
    cp -a /system/app/Iap2ServerApp.apk "$FAKE/iap.apk"
    cp -a /system/app/Iap2ServerApp.odex "$FAKE/iap.odex"
    cp -a /system/app/Bluetooth.apk "$FAKE/bt.apk"
    cp -a /system/app/Bluetooth.odex "$FAKE/bt.odex"
}

echo "hooks via $HOOK_SH"
seed
run_hook pre.sh
run_hook post.sh
cmp -s /system/app/HKMC_DiPO.apk "$PKG/files/patched/HKMC_DiPO.apk"
cmp -s /system/app/Iap2ServerApp.apk "$PKG/files/patched/Iap2ServerApp.apk"
cmp -s /system/app/Bluetooth.apk "$PKG/files/patched/Bluetooth.apk"
[ ! -e /system/app/HKMC_DiPO.odex ]
[ ! -e /system/app/Iap2ServerApp.odex ]
[ ! -e /system/app/Bluetooth.odex ]
grep -q '^persist.sys.iap2.wifi=t$' /system/build.prop
grep -q '^persist.sys.iap2.btconnection=t$' /system/build.prop
grep -q '^persist.ium.support=carplay$' /system/build.prop
grep -q '^t$' /data/property/persist.sys.iap2.wifi
grep -q '^t$' /data/property/persist.sys.iap2.btconnection
cmp -s /data/nemesis/backup/carplay.session/HKMC_DiPO.apk "$FAKE/dipo.apk"
cmp -s /data/nemesis/backup/carplay.session/HKMC_DiPO.odex "$FAKE/dipo.odex"
cmp -s /data/nemesis/backup/carplay.session/Iap2ServerApp.apk "$FAKE/iap.apk"
cmp -s /data/nemesis/backup/carplay.session/Iap2ServerApp.odex "$FAKE/iap.odex"
cmp -s /data/nemesis/backup/carplay.session/Bluetooth.apk "$FAKE/bt.apk"
cmp -s /data/nemesis/backup/carplay.session/Bluetooth.odex "$FAKE/bt.odex"
cp -a /data/nemesis/backup/carplay.session "$FAKE/snap1"
run_hook post.sh
diff -rq "$FAKE/snap1" /data/nemesis/backup/carplay.session
run_hook preun.sh
cmp -s /system/app/HKMC_DiPO.apk "$FAKE/dipo.apk"
cmp -s /system/app/HKMC_DiPO.odex "$FAKE/dipo.odex"
cmp -s /system/app/Iap2ServerApp.apk "$FAKE/iap.apk"
cmp -s /system/app/Iap2ServerApp.odex "$FAKE/iap.odex"
cmp -s /system/app/Bluetooth.apk "$FAKE/bt.apk"
cmp -s /system/app/Bluetooth.odex "$FAKE/bt.odex"
cmp -s /system/build.prop "$FAKE/bp.orig"
[ ! -e /data/property/persist.sys.iap2.wifi ]
[ ! -e /data/property/persist.sys.iap2.btconnection ]
[ ! -e /data/nemesis/backup/carplay.session ]
echo "install/uninstall ok"

seed
printf 'x' >> /system/app/HKMC_DiPO.odex
cp -a /system/app/HKMC_DiPO.apk "$FAKE/dipo.before"
set +e
( cd "$PKG" && "$HOOK_SH" ./scripts/pre.sh ) >"$FAKE/hook.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ]
grep -q 'checksum' "$FAKE/hook.out"
cmp -s /system/app/HKMC_DiPO.apk "$FAKE/dipo.before"
[ -f /system/app/HKMC_DiPO.odex ]
[ -f /system/app/Iap2ServerApp.odex ]
[ -f /system/app/Bluetooth.odex ]
cmp -s /system/build.prop "$FAKE/bp.orig"
echo "checksum gate ok"

seed
printf '%s\n' OTHER > /data/property/ro.build.product
printf '%s\n' OTHERID > /data/property/ro.build.id
run_hook pre.sh
run_hook post.sh
cmp -s /system/app/HKMC_DiPO.apk "$PKG/files/patched/HKMC_DiPO.apk"
grep -q '^persist.sys.iap2.wifi=t$' /system/build.prop
run_hook preun.sh
cmp -s /system/app/HKMC_DiPO.odex "$FAKE/dipo.odex"
cmp -s /system/build.prop "$FAKE/bp.orig"
echo "product string ignored ok"

echo "ALL CARPLAY SESSION HOOK TESTS PASSED ($HOOK_SH)"
