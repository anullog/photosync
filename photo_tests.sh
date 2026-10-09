#!/usr/bin/env bash
# Tests for photo.sh pure logic. rsync/exiftool execution is device-tested separately.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/photo.sh"
set +e +u +o pipefail; trap - EXIT INT TERM
BOLD=''; RED=''; GRN=''; YLW=''; NC=''

P=0; F=0; FN=()
ok_(){ P=$((P+1)); }
bad_(){ F=$((F+1)); FN+=("$1"); printf '  FAIL %s  %s\n' "$1" "${2:-}"; }
eq(){ [[ "$2" == "$3" ]] && ok_ || bad_ "$1" "want [$3] got [$2]"; }
true_(){ local n="$1"; shift; "$@" >/dev/null 2>&1 && ok_ || bad_ "$n"; }
rcN(){ [[ "$2" -ne 0 ]] && ok_ || bad_ "$1" "expected non-zero"; }

# _ver_ge
true_ "3.1.3>=3.1" _ver_ge 3 1 "3.1.3"
true_ "3.2.7>=3.2" _ver_ge 3 2 "3.2.7"
( _ver_ge 3 2 "3.1.3" ); rcN "3.1.3 !>= 3.2" $?
( _ver_ge 3 1 "2.6.9" ); rcN "2.6.9 !>= 3.1" $?
( _ver_ge 3 1 "" );      rcN "empty !>= 3.1" $?

# _shift_token
eq "shift +2"  "$(_shift_token 2)"   "-AllDates+=0:0:0 2:0:0"
eq "shift -3"  "$(_shift_token -3)"  "-AllDates-=0:0:0 3:0:0"
eq "shift 11"  "$(_shift_token 11)"  "-AllDates+=0:0:0 11:0:0"

# _problems (verify filter)
fx="$(printf '%s\n' '>f+++++++++ miss.arw' '>fc.t...... chk.arw' '>f.s....... siz.arw' '>f..t...... time.arw' '.f...p..... perm.arw' 'cd+++++++++ dir/')"
out="$(printf '%s\n' "$fx" | _problems)"
true_ "flags missing"  bash -c "printf '%s' \"$out\" | grep -q miss.arw"
true_ "flags checksum" bash -c "printf '%s' \"$out\" | grep -q chk.arw"
true_ "flags size"     bash -c "printf '%s' \"$out\" | grep -q siz.arw"
case "$out" in *time.arw*) bad_ "ignores time-only";; *) ok_;; esac
case "$out" in *perm.arw*) bad_ "ignores perms-only";; *) ok_;; esac
case "$out" in *dir/*)     bad_ "ignores new dir";;    *) ok_;; esac
eq "clean -> empty" "$(printf '' | _problems)" ""

# _nonempty
t="$(mktemp -d)"; mkdir -p "$t/e"; : > "$t/f.txt"
true_ "nonempty detects file"  _nonempty "$t"
( _nonempty "$t/e" ); rcN "empty dir -> false" $?
rm -rf "$t"

# EXCLUDES sanity
case "${EXCLUDES[*]}" in *.DS_Store*) ok_;; *) bad_ "excludes .DS_Store";; esac

printf '\n%s\n' "----------------------"
if [[ "$F" -eq 0 ]]; then printf 'All %d passed.\n' "$P"; exit 0
else printf '%d passed, %d FAILED: %s\n' "$P" "$F" "${FN[*]}"; exit 1; fi
