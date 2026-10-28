#!/bin/bash
# Host check that uninstall and wipe keep a package's stock-file snapshot when
# its preuninstall cannot restore. Builds the CLI with the host compiler (see
# tests/host/) and runs it in a private root, so /system and /data are fakes.
# Requires a user+mount namespace (unshare), a C compiler and zlib headers.
set -euo pipefail

# Repo root, from this file. Inside the private root the repo is bind-mounted
# at the same path, so this resolves the same there.
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "${NEMESIS_HOOK_NS:-}" != 1 ]; then
    if ! command -v unshare >/dev/null 2>&1; then
        echo "FAIL: unshare is not installed"
        exit 1
    fi
    if ! unshare --user --map-root-user --mount true; then
        echo "FAIL: unshare user+mount namespace is not available"
        exit 1
    fi
    NEMESIS_HOOK_NS=1
    # Hooks run as /system/bin/sh, which is mksh on the head unit.
    NEMESIS_DEV_SH=$(command -v mksh || command -v bash)
    NEMESIS_PYLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
    NEMESIS_ROOTFS=$(mktemp -d /tmp/nemesis-rootfs.XXXXXX)
    NEMESIS_REPO=$ROOT
    export NEMESIS_HOOK_NS NEMESIS_DEV_SH NEMESIS_PYLIB NEMESIS_ROOTFS NEMESIS_REPO
    # -Wno-unused-result: glibc marks setuid/write/chdir, bionic does not.
    if ! "${CC:-cc}" -O1 -Wall -Wno-unused-result -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 \
            -I "$ROOT/tests/host" -o "$NEMESIS_ROOTFS/nemesis" \
            "$ROOT"/native/*.c -lz; then
        rm -rf "$NEMESIS_ROOTFS"
        echo "FAIL: host build of native/ failed"
        exit 1
    fi
    set +e
    unshare --user --map-root-user --mount bash -c '
        set -euo pipefail
        r="$NEMESIS_ROOTFS/r"
        pylib="$NEMESIS_PYLIB"
        mkdir -p "$r/usr/bin" "$r/usr/lib64" "$r/usr/lib/x86_64-linux-gnu" "$r$pylib" \
            "$r/dev" "$r/system/bin" "$r/system/xbin" "$r/data" "$r/tmp" "$r$NEMESIS_REPO" "$r/etc"
        mount --bind /usr/bin "$r/usr/bin"
        mount --bind /usr/lib64 "$r/usr/lib64"
        mount --bind /usr/lib/x86_64-linux-gnu "$r/usr/lib/x86_64-linux-gnu"
        mount --bind "$pylib" "$r$pylib"
        mount --bind "$NEMESIS_REPO" "$r$NEMESIS_REPO"
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
        ln -s "$NEMESIS_DEV_SH" "$r/system/bin/sh"
        cp "$NEMESIS_ROOTFS/nemesis" "$r/system/xbin/nemesis"
        printf "%s\n" private > "$r/.nemesis-hook-private"
        chroot "$r" /bin/bash "$NEMESIS_REPO/tests/host_wipe_safety.sh"
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

N=/system/xbin/nemesis
ID=safety.fail
SNAP=/data/nemesis/backup/$ID/saved
FLAG=/data/fail-restore
WORK=$(mktemp -d /tmp/nemesis-safety.XXXXXX)

fail() {
    echo "FAIL: $*"
    if [ -f /data/nemesis/nemesis.log ]; then
        echo "---- nemesis.log ----"
        cat /data/nemesis/nemesis.log
    fi
    exit 1
}

# run <expected-rc> <args...>: run the CLI, keep its output in $WORK/out.
run() {
    local want="$1"
    shift
    local rc=0
    "$N" "$@" >"$WORK/out" 2>&1 || rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "---- nemesis $* ----"
        cat "$WORK/out"
        fail "nemesis $* returned $rc, want $want"
    fi
}

# Package whose postinstall takes a snapshot and whose preuninstall restores
# it, failing while $FLAG exists.
PKG=$WORK/pkg
mkdir -p "$PKG/scripts" "$PKG/bin"
cat > "$PKG/NEMESIS.data" <<EOF
[nemesis]
version=1.0
id=$ID
name=Safety fail
types=application
postinstall=scripts/post.sh
preuninstall=scripts/preun.sh

[app.0]
kind=sh
path=bin/status.sh
uid=root
EOF
cat > "$PKG/scripts/post.sh" <<EOF
#!/system/bin/sh
PATH=/usr/bin:\$PATH
mkdir -p ${SNAP%/*} && echo stock > $SNAP
EOF
cat > "$PKG/scripts/preun.sh" <<EOF
#!/system/bin/sh
PATH=/usr/bin:\$PATH
[ -f $FLAG ] && exit 1
rm -rf ${SNAP%/*}
exit 0
EOF
printf '#!/system/bin/sh\necho ok\n' > "$PKG/bin/status.sh"
python3 "$ROOT/tools/make_nemesis_package.py" "$PKG" -o "$WORK/pkg.zip" >/dev/null

run 0 install "$WORK/pkg.zip"
run 0 pkg-list
grep -q "$ID" "$WORK/out" || fail "$ID not listed after install"
[ -f "$SNAP" ] || fail "postinstall did not take a snapshot"

# A failed restore keeps the package and its snapshot.
touch "$FLAG"
run 3 uninstall "$ID"
grep -q "package kept" "$WORK/out" || fail "uninstall did not say the package was kept"
run 0 pkg-list
grep -q "$ID" "$WORK/out" || fail "$ID was removed although preuninstall failed"
[ -f "$SNAP" ] || fail "snapshot lost after failed uninstall"
echo "ok: uninstall keeps the package when preuninstall fails"

# Wipe aborts before deleting anything.
run 1 wipe --confirm
grep -q "wipe aborted" "$WORK/out" || fail "wipe did not report abort"
[ -f "$SNAP" ] || fail "snapshot lost after aborted wipe"
[ -x "$N" ] || fail "aborted wipe removed the CLI"
echo "ok: wipe aborts and keeps /data/nemesis/backup"

# Once the restore works, wipe completes.
rm -f "$FLAG"
run 0 wipe --confirm
grep -q "ok wiped" "$WORK/out" || fail "wipe did not finish"
[ ! -e "$N" ] || fail "wipe left the CLI"
# wipe logs "wipe done" after removing /data/nemesis, which recreates the log.
for p in /data/nemesis/* /data/nemesis/.[!.]*; do
    [ -e "$p" ] || continue
    [ "$p" = /data/nemesis/nemesis.log ] || fail "wipe left $p"
done
echo "ok: wipe completes after a successful restore"

rm -rf "$WORK"
echo "ALL WIPE SAFETY TESTS PASSED"
