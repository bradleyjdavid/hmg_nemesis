#!/bin/bash
# Syntax-check every tracked shell script with the shell it runs under.
# Device scripts (#!/system/bin/sh, and qb_hook.sh, which is appended to the
# stock qb_runtime.sh) run under mksh on the head unit, so they are parsed by
# mksh. Host scripts use their own shebang. Set MKSH to override the binary.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MKSH=${MKSH:-mksh}
if ! command -v "$MKSH" >/dev/null 2>&1; then
    echo "FAIL: $MKSH is not installed (apt install mksh)"
    exit 1
fi

fails=0
n=0
cd "$ROOT/.." || exit 1
while IFS= read -r f; do
    first=$(head -n 1 "$f")
    case "$first" in
        "#!/system/bin/sh"*) sh_bin=$MKSH ;;
        "#!/bin/bash"*|"#!/usr/bin/env bash"*) sh_bin=bash ;;
        "#!/bin/sh"*) sh_bin=sh ;;
        *)
            case "$f" in
                */boot/qb_hook.sh) sh_bin=$MKSH ;;
                *)
                    echo "FAIL: $f: no shebang this check knows"
                    fails=$((fails + 1))
                    continue
                    ;;
            esac
            ;;
    esac
    n=$((n + 1))
    if ! out=$("$sh_bin" -n "$f" 2>&1); then
        echo "FAIL: $f ($sh_bin)"
        echo "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    fi
done < <(git ls-files '*.sh')

echo "checked $n shell scripts, $fails failed"
[ "$fails" -eq 0 ]
