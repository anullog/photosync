#!/usr/bin/env bash
# Tests for photo.sh: pure helpers, then copy/sync/verify end to end on temp folders, once per
# rsync found (Homebrew rsync 3.x and/or macOS's built-in openrsync).
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/photo.sh"
set +e +u +o pipefail; IFS=$' \t\n'
BOLD=''; RED=''; GRN=''; YLW=''; NC=''

T="$(mktemp -d "${TMPDIR:-/tmp}/photo_tests.XXXXXX")" && [[ -d "$T" ]] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

P=0; F=0; FN=()
ok_(){ P=$((P+1)); }
bad_(){ F=$((F+1)); FN+=("$1"); printf '  FAIL %s  %s\n' "$1" "${2:-}"; }
eq(){ [[ "$2" == "$3" ]] && ok_ || bad_ "$1" "want [$3] got [$2]"; }
has(){ [[ "$2" == *"$3"* ]] && ok_ || bad_ "$1" "no [$3] in: $2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok_ || bad_ "$1" "unexpected [$3]"; }
true_(){ local n="$1"; shift; "$@" >/dev/null 2>&1 && ok_ || bad_ "$n"; }
false_(){ local n="$1"; shift; "$@" >/dev/null 2>&1 && bad_ "$n" "expected failure" || ok_; }
exists(){ [[ -e "$2" ]] && ok_ || bad_ "$1" "missing $2"; }
gone(){ [[ ! -e "$2" ]] && ok_ || bad_ "$1" "still there: $2"; }

# _ver_ge
true_  "3.1.3>=3.1"    _ver_ge 3 1 "3.1.3"
true_  "3.2.7>=3.2"    _ver_ge 3 2 "3.2.7"
false_ "3.1.3 !>= 3.2" _ver_ge 3 2 "3.1.3"
false_ "2.6.9 !>= 3.1" _ver_ge 3 1 "2.6.9"
false_ "empty !>= 3.1" _ver_ge 3 1 ""

# _problems: rsync 3.x (11-char) and openrsync (9-char) codes
out="$(printf '%s\n' '>f+++++++++ miss3.arw' '>f+++++++ missO.arw' '>fc.T...... chk3.arw' '>fc.T.... chkO.arw' \
                     '.f...p..... perm.arw' 'cd+++++++++ dir/' | _problems)"
has   "missing (rsync 3)"   "$out" "missing  miss3.arw"
has   "missing (openrsync)" "$out" "missing  missO.arw"
has   "differs (rsync 3)"   "$out" "differs  chk3.arw"
has   "differs (openrsync)" "$out" "differs  chkO.arw"
hasnt "ignores perms-only"  "$out" "perm.arw"
hasnt "ignores dirs"        "$out" "dir/"
eq "clean -> empty" "$(printf '' | _problems)" ""

# _deletions / _replacements
fx="$(printf '%s\n' '*deleting   old.arw' '*deleting olddir/' '>f+++++++++ new.arw' '>f+++++++ newO.arw' \
                    '>f.st...... changed.arw' '>f..T.... touched.arw' 'cd+++++++++ dir/')"
eq "deletions: files only"       "$(printf '%s\n' "$fx" | _deletions)"    "old.arw"
eq "replacements: existing only" "$(printf '%s\n' "$fx" | _replacements)" "$(printf '%s\n' changed.arw touched.arw)"
eq "_n empty" "$(_n '')" 0
eq "_n two"   "$(_n "$(printf 'a\nb')")" 2

# _nonempty
d="$T/ne"; mkdir -p "$d/empty" "$d/files/sub" "$d/card/.fseventsd" "$d/card/.Spotlight-V100" "$d/card/System Volume Information"
: > "$d/files/sub/a.arw"; : > "$d/card/.fseventsd/x"; : > "$d/card/.Spotlight-V100/y"
: > "$d/card/System Volume Information/z"; : > "$d/card/._junk"
true_  "nonempty: nested file"        _nonempty "$d/files"
false_ "nonempty: empty dir"          _nonempty "$d/empty"
false_ "nonempty: only system files"  _nonempty "$d/card"
( cd "$d/files" && _nonempty . ); eq "nonempty: works on '.'" "$?" 0

# EXCLUDES sanity
has "excludes .DS_Store" "${EXCLUDES[*]}" ".DS_Store"

# ---- end to end: run photo.sh as a command ----
run(){ OUT="$("$BASH" "$HERE/photo.sh" "$@" 2>&1 </dev/null)"; RC=$?; }                       # no answer to prompts
answer(){ local a="$1"; shift; OUT="$(printf '%s\n' "$a" | "$BASH" "$HERE/photo.sh" "$@" 2>&1)"; RC=$?; }
mk(){ mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; touch -t 202401010000 "$1"; }   # fixed mtime

run copy "$T/a" "$T/b" -n;  eq "copy: unknown option rc" "$RC" 1; has "copy: unknown option msg" "$OUT" "unknown option: -n"
run sync "$T/a" "$T/b" -c;  eq "sync: unknown option rc" "$RC" 1; has "sync: unknown option msg" "$OUT" "unknown option: -c"
run frobnicate;             eq "unknown command rc" "$RC" 1
run rename "$T";            eq "rename is gone" "$RC" 1

IMPLS=()
for r in "$(command -v rsync)" /usr/bin/rsync; do
    [[ -x "$r" ]] || continue
    dup=0; for s in "${IMPLS[@]}"; do [[ "$s" -ef "$r" ]] && dup=1; done
    [[ "$dup" -eq 0 ]] && IMPLS+=("$r")
done
[[ "${#IMPLS[@]}" -gt 0 ]] || bad_ "no rsync found for end-to-end tests"

for R in "${IMPLS[@]}"; do
    case "$("$R" --version 2>&1)" in *openrsync*) t=openrsync;; *) t=rsync;; esac
    B="$T/bin-$t"; mkdir -p "$B"; ln -sf "$R" "$B/rsync"
    SAVED_PATH="$PATH"; PATH="$B:$PATH"; W="$T/$t"

    # copy: new files, system folders skipped, re-run needs no answer
    mk "$W/card/DCIM/A.ARW" aaa; mk "$W/card/DCIM/B.ARW" bbbb; mk "$W/card/.fseventsd/x" sys
    run copy "$W/card" "$W/laptop"
    eq     "$t copy: rc"                 "$RC" 0
    eq     "$t copy: content"            "$(cat "$W/laptop/DCIM/B.ARW")" bbbb
    gone   "$t copy: skips .fseventsd"   "$W/laptop/.fseventsd"
    run copy "$W/card" "$W/laptop"
    eq     "$t copy rerun: no prompt"    "$RC" 0

    # copy: same name, different photo → asks; kept on no answer, replaced on y
    mk "$W/card2/DCIM/A.ARW" other-photo
    run copy "$W/card2" "$W/laptop"
    eq     "$t clash: aborts unanswered" "$RC" 1
    has    "$t clash: names the file"    "$OUT" "DCIM/A.ARW"
    eq     "$t clash: original kept"     "$(cat "$W/laptop/DCIM/A.ARW")" aaa
    answer y copy "$W/card2" "$W/laptop"
    eq     "$t clash: replaced on y"     "$(cat "$W/laptop/DCIM/A.ARW")" other-photo

    # copy -c and verify: clean, then a missing file and same-size/same-date changed bytes
    run copy "$W/card" "$W/disk" -c
    eq     "$t copy -c: rc"              "$RC" 0
    has    "$t copy -c: match"           "$OUT" "checksums match"
    run verify "$W/card" "$W/disk"
    eq     "$t verify clean: rc"         "$RC" 0
    rm "$W/disk/DCIM/A.ARW"; mk "$W/disk/DCIM/B.ARW" XXXX
    run verify "$W/card" "$W/disk"
    eq     "$t verify: fails"            "$RC" 1
    has    "$t verify: missing file"     "$OUT" "missing  DCIM/A.ARW"
    has    "$t verify: changed bytes"    "$OUT" "differs  DCIM/B.ARW"

    # sync: deletions and replacements are listed and need a y
    run sync "$W/card" "$W/bk"
    eq     "$t sync fresh: rc"           "$RC" 0
    mk "$W/bk/DCIM/extra.ARW" e; mkdir -p "$W/bk/olddir"; mk "$W/bk/DCIM/B.ARW" edited-on-backup
    run sync "$W/card" "$W/bk"
    eq     "$t sync: aborts unanswered"  "$RC" 1
    has    "$t sync: counts files only"  "$OUT" "1 file(s) on DST will be DELETED"
    has    "$t sync: lists replacement"  "$OUT" "1 file(s) on DST will be REPLACED"
    exists "$t sync: nothing deleted"    "$W/bk/DCIM/extra.ARW"
    answer y sync "$W/card" "$W/bk"
    eq     "$t sync y: rc"               "$RC" 0
    gone   "$t sync y: deleted"          "$W/bk/DCIM/extra.ARW"
    eq     "$t sync y: replaced"         "$(cat "$W/bk/DCIM/B.ARW")" bbbb

    # sync: a freshly formatted card (only .fseventsd) must not wipe DST
    mk "$W/blank/.fseventsd/x" sys
    run sync "$W/blank" "$W/bk"
    eq     "$t blank card: refused"      "$RC" 1
    has    "$t blank card: message"      "$OUT" "Refusing to mirror"
    exists "$t blank card: DST intact"   "$W/bk/DCIM/A.ARW"

    PATH="$SAVED_PATH"
done

printf '\n%s\n' "----------------------"
if [[ "$F" -eq 0 ]]; then printf 'All %d passed (rsync: %s).\n' "$P" "${IMPLS[*]}"; exit 0
else printf '%d passed, %d FAILED: %s\n' "$P" "$F" "${FN[*]}"; exit 1; fi
