#!/usr/bin/env bash
# Tests for photo.sh: pure helpers, then copy/sync/verify end to end on temp folders, once per
# rsync found (Homebrew rsync 3.x and/or the macOS built-in). Run:  /bin/bash photo_tests.sh
#
# photo.sh must work with the stock bash 3.2, so the suite re-runs itself under /bin/bash if started
# by a newer bash (e.g. Homebrew's).
if [[ "${BASH_VERSINFO[0]}" -gt 3 && -x /bin/bash && -z "${PHOTO_TESTS_REEXEC:-}" ]] &&
   [[ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" == 3 ]]; then
    PHOTO_TESTS_REEXEC=1 exec /bin/bash "$0" "$@"
fi
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)" || exit 1
source "$HERE/photo.sh" || { echo "cannot load $HERE/photo.sh" >&2; exit 1; }
IFS=$' \t\n'
BOLD=''; RED=''; GRN=''; YLW=''; NC=''; NC2=''
unset PHOTO_SH_TEST_ANSWER

T="$(mktemp -d "${TMPDIR:-/tmp}/photo_tests.XXXXXX")" && [[ -d "$T" ]] || { echo "mktemp failed"; exit 1; }
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

P=0; F=0; FN=()
ok_(){ P=$((P+1)); }
bad_(){ F=$((F+1)); FN+=("$1"); printf '  FAIL %s  %s\n' "$1" "${2:-}"; }
eq(){ [[ "$2" == "$3" ]] && ok_ || bad_ "$1" "want [$3] got [$2]"; }
has(){ [[ "$2" == *"$3"* ]] && ok_ || bad_ "$1" "no [$3] in: $2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok_ || bad_ "$1" "unexpected [$3] in: $2"; }
line(){ printf '%s\n' "$2" | grep -qxF -- "$3" && ok_ || bad_ "$1" "no line [$3] in: $2"; }
true_(){ local n="$1"; shift; "$@" >/dev/null 2>&1 && ok_ || bad_ "$n"; }
false_(){ local n="$1" rc; shift; "$@" >/dev/null 2>&1; rc=$?; [[ "$rc" -eq 1 ]] && ok_ || bad_ "$n" "want exit 1, got $rc"; }
exists(){ [[ -e "$2" || -L "$2" ]] && ok_ || bad_ "$1" "missing $2"; }
gone(){ [[ ! -e "$2" && ! -L "$2" ]] && ok_ || bad_ "$1" "still there: $2"; }
isfile(){ [[ -f "$2" && ! -L "$2" ]] && ok_ || bad_ "$1" "not a plain file: $2"; }

# ---- helpers -------------------------------------------------------------------------------------
# _ver_ge
true_  "3.1.3>=3.1"    _ver_ge 3 1 "3.1.3"
true_  "3.2.7>=3.2"    _ver_ge 3 2 "3.2.7"
false_ "3.1.3 !>= 3.2" _ver_ge 3 2 "3.1.3"
false_ "2.6.9 !>= 3.1" _ver_ge 3 1 "2.6.9"
false_ "empty !>= 3.1" _ver_ge 3 1 ""

# _problems: rsync 3.x (11-char) and openrsync (9-char) codes
out="$(printf '%s\n' '>f+++++++++ miss3.arw' '>f+++++++ missO.arw' '>fc.T...... chk3.arw' '>fc.T.... chkO.arw' \
                     '.f...p..... perm.arw' '.f..T.... sameO.arw' 'cd+++++++++ dir/' | _problems)"
has   "missing (rsync 3)"   "$out" "missing  miss3.arw"
has   "missing (openrsync)" "$out" "missing  missO.arw"
has   "differs (rsync 3)"   "$out" "differs  chk3.arw"
has   "differs (openrsync)" "$out" "differs  chkO.arw"
hasnt "ignores perms-only"  "$out" "perm.arw"
hasnt "ignores date-only"   "$out" "sameO.arw"
hasnt "ignores dirs"        "$out" "dir/"
eq "clean -> empty" "$(printf '' | _problems)" ""

# names: leading spaces kept, UTF-8 bytes escaped by rsync restored, controls stay escaped
U8(){ LC_ALL=en_US.UTF-8 "$@"; }   # the filters must work whatever the caller's locale
eq "name: leading spaces" "$(printf '%s\n' '>f.s.......   lead.arw' | U8 _replacements)" "  lead.arw"
eq "name: \\#ooo UTF-8"   "$(printf '%s\n' '>fc.T.... Z\#303\#274rich.arw' | U8 _problems)" "differs  Zürich.arw"
eq "name: partial (openrsync)" "$(printf '%s\n' $'>f.s..... \xc3\\#234ber.arw' | U8 _replacements)" "Über.arw"
eq "name: partial, verify" "$(printf '%s\n' $'>fc.T.... \xc3\\#234ber.arw' | U8 _problems)" "differs  Über.arw"
eq "name: control kept escaped" "$(printf '%s\n' '>f.s..... a\#012b.arw' | U8 _replacements)" 'a\#012b.arw'
# must not crash in a UTF-8 locale on openrsync's partial escapes (the filter would see no files)
eq "UTF-8 locale: no crash" "$(printf '%s\n' $'*deleting \xe2\\#200\\#223 x/a.arw' | LC_ALL=en_US.UTF-8 IW=9 _deletions)" "– x/a.arw"

# _deletions / _replacements
fx="$(printf '%s\n' '*deleting   old.arw' '*deleting olddir/' '>f+++++++++ new.arw' '>f+++++++ newO.arw' \
                    '>f.st...... changed.arw' '>f..T.... touched.arw' 'cd+++++++++ dir/' 'cLc........ ln' \
                    'cL+++++++++ newln')"
IW=11; eq "deletions: files only"       "$(printf '%s\n' "$fx" | _deletions)"    "old.arw"
eq "replacements: existing only" "$(printf '%s\n' "$fx" | _replacements)" "$(printf '%s\n' changed.arw touched.arw ln)"
IW=11; eq "deletions: rsync 3 width" "$(printf '%s\n' '*deleting     two.arw' | _deletions)" "  two.arw"
IW=9;  eq "deletions: openrsync width" "$(printf '%s\n' '*deleting   two.arw' | _deletions)" "  two.arw"
IW=9;  eq "deletions: dedup (openrsync)" "$(printf '%s\n' '*deleting d/a' '*deleting d/a' '*deleting d/' | _deletions)" "d/a"
IW=9;  eq "deletions: hide clutter" "$(printf '%s\n' '*deleting e/.DS_Store' '*deleting e/._a.arw' '*deleting e/.Spotlight-V100/x' '*deleting e/a.arw' | _deletions)" "e/a.arw"
IW=11
eq "_n empty" "$(_n '')" 0
eq "_n two"   "$(_n "$(printf 'a\nb')")" 2

# _list: cap at 20 with a count; bidi overrides and C1 controls masked, normal UTF-8 kept
out="$(for i in $(seq 1 25); do echo "f$i"; done | _list)"
has   "list: shows 20"     "$out" "    f20"
hasnt "list: hides 21"     "$out" "    f21"
has   "list: count"        "$out" "… and 5 more"
eq    "list: masks"        "$(printf '%s\n' $'caf\xc3\xa9 \xe2\x80\xaegpj.ARW a\xe2\x80\x93b \xc2\x9bx' | _list)" "    café ?gpj.ARW a–b ?x"

# _nonempty / _count_files
d="$T/ne"; mkdir -p "$d/empty" "$d/files/sub" "$d/card/.fseventsd" "$d/card/.Spotlight-V100" "$d/card/System Volume Information"
: > "$d/files/sub/a.arw"; : > "$d/files/.DS_Store"; : > "$d/files/._a.arw"; : > "$d/files/.hidden.arw"
: > "$d/card/.fseventsd/x"; : > "$d/card/.Spotlight-V100/y"; : > "$d/card/System Volume Information/z"; : > "$d/card/._junk"
true_  "nonempty: nested file"        _nonempty "$d/files"
false_ "nonempty: empty dir"          _nonempty "$d/empty"
false_ "nonempty: only system files"  _nonempty "$d/card"
( cd "$d/files" && _nonempty . ); eq "nonempty: works on '.'" "$?" 0
eq "count: skips clutter"  "$(_count_files "$d/files")" 2
eq "count: system only"    "$(_count_files "$d/card")" 0

# _local: rsync must never see host:path or an option
eq "local: relative"  "$(_local 'shoot 10:30')" "./shoot 10:30"
eq "local: dash"      "$(_local '-x')" "./-x"
eq "local: absolute"  "$(_local /a/b)" "/a/b"

# _no_overlap (dies → run in a subshell)
o="$T/ov"; mkdir -p "$o/lib/2024" "$o/other"; ln -s "$o/lib" "$o/alias"
false_ "overlap: same"            eval '( _no_overlap copy "$o/lib" "$o/lib" )'
false_ "overlap: via symlink"     eval '( _no_overlap copy "$o/lib" "$o/alias/" )'
false_ "overlap: DST inside SRC"  eval '( _no_overlap copy "$o/lib" "$o/lib/new/deeper" )'
false_ "overlap: sync SRC in DST" eval '( _no_overlap sync "$o/lib/2024" "$o/lib" )'
true_  "overlap: copy SRC in DST" eval '( _no_overlap copy "$o/lib/2024" "$o/lib" )'
true_  "overlap: unrelated"       eval '( _no_overlap sync "$o/lib" "$o/other/new" )'
true_  "overlap: name prefix"     eval '( mkdir -p "$o/lib2"; _no_overlap sync "$o/lib" "$o/lib2" )'
if [[ -d "$o/LIB" ]]; then   # case-insensitive volume (the macOS default)
    false_ "overlap: case only" eval '( _no_overlap sync "$o/lib/2024" "$o/LIB" )'
fi

has "excludes .DS_Store" "${EXCLUDES[*]}" ".DS_Store"

# ---- end to end: run photo.sh as a command -------------------------------------------------------
# stdin is never a terminal here. PHOTO_SH_TEST_ANSWER stands in for the answer typed on one.
run(){ OUT="$("$BASH" "$HERE/photo.sh" "$@" 2>&1 </dev/null)"; RC=$?; }
answer(){ local a="$1"; shift; OUT="$(PHOTO_SH_TEST_ANSWER="$a" "$BASH" "$HERE/photo.sh" "$@" 2>&1 </dev/null)"; RC=$?; }
mk(){ mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; touch -t 202401010000 "$1"; }   # fixed mtime

run copy "$T/a" "$T/b" -n;  eq "copy: unknown option rc" "$RC" 2; has "copy: unknown option msg" "$OUT" "unknown option: -n"
run sync "$T/a" "$T/b" -c;  eq "sync: unknown option rc" "$RC" 2; has "sync: unknown option msg" "$OUT" "unknown option: -c"
run copy "$T/a";            eq "copy: one arg rc" "$RC" 2;        has "copy: usage" "$OUT" "usage: photo.sh copy SRC DST [-c]"
run frobnicate;             eq "unknown command rc" "$RC" 2
run rename "$T";            eq "rename is gone" "$RC" 2
run;                        eq "no args rc" "$RC" 2
run --help;                 eq "help rc" "$RC" 0;                 has "help text" "$OUT" "photo.sh verify SRC DST"
run sync -h;                eq "sync -h rc" "$RC" 0
run --version;              eq "version rc" "$RC" 0;              has "version text" "$OUT" "photo.sh $VERSION"
if command -v zsh >/dev/null 2>&1; then
    OUT="$(zsh "$HERE/photo.sh" copy a b 2>&1)"; eq "zsh: refused rc" "$?" 2; has "zsh: message" "$OUT" "needs bash"
fi

IMPLS=()
for r in "$(command -v rsync)" /usr/bin/rsync; do
    [[ -x "$r" ]] || continue
    dup=0; for s in "${IMPLS[@]}"; do [[ "$s" -ef "$r" ]] && dup=1; done
    [[ "$dup" -eq 0 ]] && IMPLS+=("$r")
done
[[ "${#IMPLS[@]}" -gt 0 ]] || bad_ "no rsync found for end-to-end tests"

# openrsync starts its receiver as `rsync --server` from PATH, so each rsync is tested by putting a
# symlink named rsync first in PATH, never by calling it by absolute path.
n=0
for R in "${IMPLS[@]}"; do
    n=$((n+1))
    case "$("$R" --version 2>&1)" in *openrsync*) t=openrsync$n;; *) t=rsync$n;; esac
    printf '%s: %s\n' "$t" "$("$R" --version 2>&1 | head -1)"
    B="$T/bin-$t"; mkdir -p "$B"; ln -sf "$R" "$B/rsync"
    SAVED_PATH="$PATH"; PATH="$B:$PATH"; W="$T/$t"
    _rsync_caps; PERISH=0; [[ "${EXCLUDES[*]}" == *"-p .DS_Store"* ]] && PERISH=1
    if [[ "$IW" -eq 11 || "$OPENRSYNC" -eq 1 ]]; then eq "$t perishable filters" "$PERISH" 1; fi

    # copy: new files, system folders skipped, re-run needs no answer and does nothing
    mk "$W/card/DCIM/A.ARW" aaa; mk "$W/card/DCIM/B.ARW" bbbb; mk "$W/card/.fseventsd/x" sys
    run copy "$W/card" "$W/laptop"
    eq     "$t copy: rc"                 "$RC" 0
    eq     "$t copy: content"            "$(cat "$W/laptop/DCIM/B.ARW")" bbbb
    gone   "$t copy: skips .fseventsd"   "$W/laptop/.fseventsd"
    run copy "$W/card" "$W/laptop"
    eq     "$t copy rerun: no prompt"    "$RC" 0
    has    "$t copy rerun: no-op"        "$OUT" "nothing to copy"
    mk "$W/laptop/DCIM/mine.ARW" keep
    run copy "$W/card" "$W/laptop"
    exists "$t copy: keeps DST-only"     "$W/laptop/DCIM/mine.ARW"

    # copy: same name, different photo → asks; kept unless the answer is exactly yes
    mk "$W/card2/DCIM/A.ARW" other-photo
    run copy "$W/card2" "$W/laptop"
    eq     "$t clash: aborts unanswered" "$RC" 1
    has    "$t clash: names the file"    "$OUT" "DCIM/A.ARW"
    eq     "$t clash: original kept"     "$(cat "$W/laptop/DCIM/A.ARW")" aaa
    for a in n N no ' y' yno; do
        answer "$a" copy "$W/card2" "$W/laptop"
        eq "$t clash: '$a' aborts" "$RC" 1
    done
    eq     "$t clash: still kept"        "$(cat "$W/laptop/DCIM/A.ARW")" aaa
    OUT="$(printf 'y\n' | "$BASH" "$HERE/photo.sh" copy "$W/card2" "$W/laptop" 2>&1)"; RC=$?
    eq     "$t clash: piped y ignored"   "$RC" 1
    eq     "$t clash: piped y kept"      "$(cat "$W/laptop/DCIM/A.ARW")" aaa
    OUT="$(PHOTO_SH_TEST_ANSWER=y "$BASH" "$HERE/photo.sh" copy "$W/card2" "$W/laptop" 2>/dev/null </dev/null)"
    hasnt  "$t clash: list not on stdout"   "$OUT" "DCIM/A.ARW"
    hasnt  "$t clash: prompt not on stdout" "$OUT" "[y/N]"
    eq     "$t clash: replaced on yes"   "$(cat "$W/laptop/DCIM/A.ARW")" other-photo

    # copy: a folder or symlink on SRC where DST has a file must be asked about, not done silently
    mk "$W/tc/s/Exports/a.jpg" new; ln -s /nowhere "$W/tc/s/IMG.ARW"; mk "$W/tc/d/Exports" precious1; mk "$W/tc/d/IMG.ARW" precious2
    run copy "$W/tc/s" "$W/tc/d"
    eq     "$t type change: asks"        "$RC" 1
    has    "$t type change: lists dir"   "$OUT" "Exports"
    has    "$t type change: lists link"  "$OUT" "IMG.ARW"
    isfile "$t type change: file kept"   "$W/tc/d/Exports"
    isfile "$t type change: file kept 2" "$W/tc/d/IMG.ARW"
    run sync "$W/tc/s" "$W/tc/d"
    eq     "$t type change sync: asks"   "$RC" 1
    isfile "$t type change sync: kept"   "$W/tc/d/Exports"

    # names: a folder with ':' is local, '-' names work after --, UTF-8 names show up correctly
    mkdir -p "$W/colon"; cd "$W/colon" || exit 1
    run copy ../card 'shoot 10:30'
    eq     "$t colon: rc"                "$RC" 0
    exists "$t colon: local copy"        "$W/colon/shoot 10:30/DCIM/A.ARW"
    run copy -- ../card -dash
    eq     "$t dash: rc"                 "$RC" 0
    exists "$t dash: copied"             "$W/colon/-dash/DCIM/A.ARW"
    cd "$HERE" || exit 1
    mk "$W/u/lib/2024/A.ARW" a; mk "$W/u/bk/2024/A.ARW" a
    mk "$W/u/bk/Zürich – Tag 1/IMG_0001.ARW" only-copy; mk "$W/u/bk/Peter’s Hochzeit/IMG_0002.ARW" only-copy-2
    mk "$W/u/bk/  lead.ARW" x
    OUT="$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$BASH" "$HERE/photo.sh" sync "$W/u/lib" "$W/u/bk" 2>&1 </dev/null)"; RC=$?
    eq     "$t UTF-8: asks"              "$RC" 1
    has    "$t UTF-8: counts all"        "$OUT" "3 file(s) on DST will be DELETED"
    line   "$t UTF-8: readable name"     "$OUT" "    Zürich – Tag 1/IMG_0001.ARW"
    line   "$t UTF-8: leading spaces"    "$OUT" "      lead.ARW"
    exists "$t UTF-8: kept"              "$W/u/bk/Zürich – Tag 1/IMG_0001.ARW"
    mk "$W/u/card/Привет/A.ARW" a; mk "$W/u/card/Привет/B.ARW" bbbb; mk "$W/u/disk/Привет/B.ARW" XXXX
    OUT="$(LC_ALL=en_US.UTF-8 "$BASH" "$HERE/photo.sh" verify "$W/u/card" "$W/u/disk" 2>&1 </dev/null)"; RC=$?
    eq     "$t UTF-8 verify: fails"      "$RC" 1
    has    "$t UTF-8 verify: missing"    "$OUT" "missing  Привет/A.ARW"
    has    "$t UTF-8 verify: differs"    "$OUT" "differs  Привет/B.ARW"

    # copy -c and verify: clean, then a missing file and same-size/same-date changed bytes
    run copy "$W/card" "$W/disk" -c
    eq     "$t copy -c: rc"              "$RC" 0
    has    "$t copy -c: match"           "$OUT" "checksums match: all 2 SRC files"
    run verify "$W/card" "$W/disk"
    eq     "$t verify clean: rc"         "$RC" 0
    rm "$W/disk/DCIM/A.ARW"; mk "$W/disk/DCIM/B.ARW" XXXX
    run verify "$W/card" "$W/disk"
    eq     "$t verify: fails"            "$RC" 1
    has    "$t verify: missing file"     "$OUT" "missing  DCIM/A.ARW"
    has    "$t verify: changed bytes"    "$OUT" "differs  DCIM/B.ARW"
    has    "$t verify: verdict"          "$OUT" "VERIFY FAILED"
    mk "$W/vd/s/D1/a" a; mk "$W/vd/s/D2/b" b; mk "$W/vd/s/D2/c" c; mk "$W/vd/d/D1/a" a
    run verify "$W/vd/s" "$W/vd/d"
    has    "$t verify: dir missing 1"    "$OUT" "missing  D2/b"
    has    "$t verify: dir missing 2"    "$OUT" "missing  D2/c"
    mkdir -p "$W/vd/empty/DCIM"
    run verify "$W/vd/empty" "$W/vd/d"
    eq     "$t verify empty SRC: rc"     "$RC" 1
    has    "$t verify empty SRC: msg"    "$OUT" "SRC has no files"
    run verify "$W/vd/s" "$W/vd/s"
    eq     "$t verify same: rc"          "$RC" 1
    has    "$t verify same: msg"         "$OUT" "same folder"

    # 2-second tolerance for FAT/exFAT dates; list capped at 20
    mk "$W/w/s/A" aaaa; mk "$W/w/d/A" aaaa; touch -t 202401010000.01 "$W/w/s/A"
    run copy "$W/w/s" "$W/w/d"
    eq     "$t 2s window: no prompt"     "$RC" 0
    for i in $(seq -w 1 25); do mk "$W/m/s/$i.ARW" x; mk "$W/m/d/$i.ARW" yy; done
    run copy "$W/m/s" "$W/m/d"
    has    "$t list: capped"             "$OUT" "… and 5 more"

    # overlap guards
    mk "$W/ov/bk/incoming/A.ARW" a; mk "$W/ov/bk/old.ARW" o
    answer y sync "$W/ov/bk/incoming" "$W/ov/bk"
    eq     "$t SRC in DST: refused"      "$RC" 1
    exists "$t SRC in DST: SRC intact"   "$W/ov/bk/incoming/A.ARW"
    run copy "$W/ov/bk" "$W/ov/bk/incoming/nested"
    eq     "$t DST in SRC: refused"      "$RC" 1
    gone   "$t DST in SRC: not created"  "$W/ov/bk/incoming/nested"
    run copy "$W/ov/bk/incoming" "$W/ov/bk"
    eq     "$t SRC in DST: copy allowed" "$RC" 0

    # sync: deletions and replacements are listed and need a yes
    run sync "$W/card" "$W/bk"
    eq     "$t sync fresh: rc"           "$RC" 0
    mk "$W/bk/DCIM/extra.ARW" e; mkdir -p "$W/bk/olddir"; mk "$W/bk/DCIM/B.ARW" edited-on-backup
    run sync "$W/card" "$W/bk"
    eq     "$t sync: aborts unanswered"  "$RC" 1
    has    "$t sync: counts files only"  "$OUT" "1 file(s) on DST will be DELETED"
    has    "$t sync: lists replacement"  "$OUT" "1 file(s) on DST will be REPLACED"
    exists "$t sync: nothing deleted"    "$W/bk/DCIM/extra.ARW"
    eq     "$t sync: nothing replaced"   "$(cat "$W/bk/DCIM/B.ARW")" edited-on-backup
    OUT="$(printf 'y\n' | "$BASH" "$HERE/photo.sh" sync "$W/card" "$W/bk" 2>&1)"; RC=$?
    eq     "$t sync: piped y ignored"    "$RC" 1
    exists "$t sync: piped y kept"       "$W/bk/DCIM/extra.ARW"
    answer y sync "$W/card" "$W/bk"
    eq     "$t sync y: rc"               "$RC" 0
    gone   "$t sync y: deleted"          "$W/bk/DCIM/extra.ARW"
    eq     "$t sync y: replaced"         "$(cat "$W/bk/DCIM/B.ARW")" bbbb
    run sync "$W/card" "$W/bk"
    has    "$t sync rerun: no-op"        "$OUT" "nothing to do"

    # sync: deleting most of DST (wrong folder?) needs the count typed, not just y
    mk "$W/mass/s/A.ARW" a; mk "$W/mass/d/A.ARW" a
    for i in $(seq -w 1 29); do mk "$W/mass/d/lib/$i.ARW" x; done
    answer y sync "$W/mass/s" "$W/mass/d"
    eq     "$t mass delete: y refused"   "$RC" 1
    has    "$t mass delete: explains"    "$OUT" "29 of the 30 files"
    exists "$t mass delete: kept"        "$W/mass/d/lib/01.ARW"
    answer 29 sync "$W/mass/s" "$W/mass/d"
    eq     "$t mass delete: count ok"    "$RC" 0
    gone   "$t mass delete: deleted"     "$W/mass/d/lib/01.ARW"

    # sync: a folder removed from SRC goes away on DST even if Finder left a .DS_Store in it
    if [[ "$PERISH" -eq 1 ]]; then
        mk "$W/jk/s/keep/A.ARW" a; mk "$W/jk/d/keep/A.ARW" a; mk "$W/jk/d/old/B.ARW" b
        mk "$W/jk/d/old/.DS_Store" junk; mk "$W/jk/d/.DS_Store" rootjunk
        answer y sync "$W/jk/s" "$W/jk/d"
        eq     "$t clutter: rc"          "$RC" 0
        has    "$t clutter: one file"    "$OUT" "1 file(s) on DST will be DELETED"
        hasnt  "$t clutter: not listed"  "$OUT" ".DS_Store"
        gone   "$t clutter: folder gone" "$W/jk/d/old"
        exists "$t clutter: root kept"   "$W/jk/d/.DS_Store"
    else   # rsync 2.x: the photo goes, the folder stays with its clutter
        mk "$W/jk/s/keep/A.ARW" a; mk "$W/jk/d/keep/A.ARW" a; mk "$W/jk/d/old/B.ARW" b; mk "$W/jk/d/old/.DS_Store" junk
        answer y sync "$W/jk/s" "$W/jk/d"
        gone   "$t clutter (2.x): photo gone" "$W/jk/d/old/B.ARW"
    fi

    # sync: a freshly formatted card (only .fseventsd) must not wipe DST, and makes no folder
    mk "$W/blank/.fseventsd/x" sys
    run sync "$W/blank" "$W/bk"
    eq     "$t blank card: refused"      "$RC" 1
    has    "$t blank card: message"      "$OUT" "Refusing to mirror"
    exists "$t blank card: DST intact"   "$W/bk/DCIM/A.ARW"
    run sync "$W/blank" "$W/typo/bk"
    gone   "$t blank card: no DST made"  "$W/typo"

    # rsync failures: a dry run that fails asks first and then replaces nothing; a failing real run
    # is reported. Fake rsyncs pass everything else (including openrsync's --server) to the real one.
    FB="$T/bin-fail-$t"; mkdir -p "$FB"
    printf '#!/bin/bash\nfor a; do [[ "$a" == --dry-run ]] && { echo "fake: dry run failed" >&2; exit 23; }; done\nexec "%s" "$@"\n' "$R" > "$FB/rsync"
    chmod +x "$FB/rsync"
    mk "$W/pf/s/A.ARW" new-version; mk "$W/pf/s/B.ARW" b; mk "$W/pf/d/A.ARW" old
    PATH="$FB:$SAVED_PATH" run copy "$W/pf/s" "$W/pf/d"
    eq     "$t preview fails: asks"      "$RC" 1
    has    "$t preview fails: says so"   "$OUT" "couldn't fully preview"
    PATH="$FB:$SAVED_PATH" answer y copy "$W/pf/s" "$W/pf/d"
    eq     "$t preview fails: y rc"      "$RC" 1
    has    "$t preview fails: warns"     "$OUT" "preview reported errors"
    eq     "$t preview fails: no replace" "$(cat "$W/pf/d/A.ARW")" old
    exists "$t preview fails: copies new" "$W/pf/d/B.ARW"
    printf '#!/bin/bash\nd=0; s=0; m=0\nfor a; do case "$a" in --dry-run) d=1;; --server) s=1;; --modify-window=2) m=1;; esac; done\n[[ $m -eq 1 && $d -eq 0 && $s -eq 0 ]] && { echo "fake: disk full" >&2; exit 11; }\nexec "%s" "$@"\n' "$R" > "$FB/rsync"
    mk "$W/rf/s/C.ARW" c
    PATH="$FB:$SAVED_PATH" run copy "$W/rf/s" "$W/rf/d"
    eq     "$t real run fails: rc"       "$RC" 1
    has    "$t real run fails: says so"  "$OUT" "rsync failed (exit 11)"

    # a filter that can't read rsync's output must stop the run, never look like "nothing to delete"
    AB="$T/bin-awk-$t"; mkdir -p "$AB"
    printf '#!/bin/bash\nfor a; do [[ "$a" == w=* ]] && exit 2; done\nexec /usr/bin/awk "$@"\n' > "$AB/awk"; chmod +x "$AB/awk"
    mk "$W/fa/s/A.ARW" a; mk "$W/fa/d/A.ARW" a; mk "$W/fa/d/extra.ARW" e
    PATH="$AB:$PATH" answer y sync "$W/fa/s" "$W/fa/d"
    eq     "$t filter fails: stops"      "$RC" 1
    has    "$t filter fails: says so"    "$OUT" "couldn't read rsync's preview"
    exists "$t filter fails: kept"       "$W/fa/d/extra.ARW"

    # SRC/DST changing after the preview: a fake rsync adds late*.ARW to DST after its Nth dry run
    LB="$T/bin-late-$t"; mkdir -p "$LB"
    late(){ rm -f "$1/cnt"; printf '#!/bin/bash\n"%s" "$@"; rc=$?\nfor a; do if [[ "$a" == --dry-run ]]; then n=$(( $(cat "%s/cnt" 2>/dev/null || echo 0) + 1 )); echo $n > "%s/cnt"; if [[ $n -eq %s ]]; then for i in 1 2 3; do : > "%s/d/late$i.ARW"; done; fi; fi; done\nexit $rc\n' \
                "$R" "$1" "$1" "$2" "$1" > "$LB/rsync"; chmod +x "$LB/rsync"; }
    mk "$W/tt/s/A.ARW" a; mk "$W/tt/d/A.ARW" a; mk "$W/tt/d/extra.ARW" e
    late "$W/tt" 1; PATH="$LB:$SAVED_PATH" answer y sync "$W/tt/s" "$W/tt/d"
    eq     "$t recheck: stops"           "$RC" 1
    has    "$t recheck: says so"         "$OUT" "changed while waiting"
    exists "$t recheck: late kept"       "$W/tt/d/late3.ARW"
    exists "$t recheck: listed kept"     "$W/tt/d/extra.ARW"
    rm -f "$W/tt/d"/late*.ARW
    late "$W/tt" 2; PATH="$LB:$SAVED_PATH" answer y sync "$W/tt/s" "$W/tt/d"   # appears after the re-check
    eq     "$t max-delete: stops"        "$RC" 1
    has    "$t max-delete: says so"      "$OUT" "stopped deleting"
    eq     "$t max-delete: one deleted"  "$(ls "$W/tt/d" | wc -l | tr -d ' ')" 4
    mk "$W/nd/s/A.ARW" a; mk "$W/nd/d/A.ARW" a; mk "$W/nd/s/B.ARW" b
    late "$W/nd" 1; PATH="$LB:$SAVED_PATH" run sync "$W/nd/s" "$W/nd/d"           # nothing to delete: no --delete
    eq     "$t no deletions: rc"         "$RC" 0
    exists "$t no deletions: late kept"  "$W/nd/d/late1.ARW"

    # empty and unresolvable path arguments
    run copy "" "$W/x";                eq "$t empty SRC: rc" "$RC" 2
    run copy -- "$W/card" "";          eq "$t empty DST: rc" "$RC" 2
    run copy "$W/card" "$W/nonexist/../card/new"
    eq     "$t ..: refused"              "$RC" 1
    gone   "$t ..: not created"          "$W/card/new"

    # copy: a DST folder where SRC has a file can't be copied over; it is reported, not skipped
    mk "$W/rv/s/Edits" file; mk "$W/rv/s/A.ARW" a; mk "$W/rv/d/Edits/.DS_Store" junk; mk "$W/rv/d/Edits/x.jpg" x
    run copy "$W/rv/s" "$W/rv/d"
    eq     "$t folder in the way: rc"    "$RC" 1
    exists "$t folder in the way: kept"  "$W/rv/d/Edits/x.jpg"

    # a symlink whose target changed is asked about (openrsync does not list it by itself)
    mkdir -p "$W/sl/s" "$W/sl/d"; mk "$W/sl/s/A.ARW" a; mk "$W/sl/d/A.ARW" a
    ln -s 2024/final "$W/sl/s/Latest"; ln -s 2023/final "$W/sl/d/Latest"
    run copy "$W/sl/s" "$W/sl/d"
    eq     "$t relink: asks"             "$RC" 1
    has    "$t relink: lists it"         "$OUT" "Latest"
    eq     "$t relink: unchanged"        "$(readlink "$W/sl/d/Latest")" 2023/final

    # exact names: a link named 'a -> b.arw' and a folder with a backslash over DST files
    mkdir -p "$W/xn/s" "$W/xn/d"; ln -s /nowhere "$W/xn/s/a -> b.arw"; mk "$W/xn/d/a -> b.arw" precious1
    mk "$W/xn/s/lit\\#123/x.jpg" x; mk "$W/xn/d/lit\\#123" precious2
    run copy "$W/xn/s" "$W/xn/d"
    eq     "$t odd names: asks"          "$RC" 1
    isfile "$t odd names: kept 1"        "$W/xn/d/a -> b.arw"
    isfile "$t odd names: kept 2"        "$W/xn/d/lit\\#123"

    # a second card synced onto the first card's folder: replacements count like deletions
    for i in $(seq -w 1 40); do mk "$W/c2/card1/DSC000$i.ARW" "card1-$i"; done
    for i in $(seq -w 1 35); do mk "$W/c2/card2/DSC000$i.ARW" "card2-photo-$i"; done
    answer y sync "$W/c2/card2" "$W/c2/card1"
    eq     "$t 2nd card sync: y refused" "$RC" 1
    has    "$t 2nd card sync: explains"  "$OUT" "40 of the 40 files"
    answer y copy "$W/c2/card2" "$W/c2/card1"
    eq     "$t 2nd card copy: y refused" "$RC" 1
    eq     "$t 2nd card: originals kept" "$(cat "$W/c2/card1/DSC00001.ARW")" card1-01

    # the real terminal: only when a pseudo-terminal can be opened here
    if script -q /dev/null /usr/bin/true >/dev/null 2>&1; then
        mk "$W/pty/s/A.ARW" new; mk "$W/pty/d/A.ARW" old
        printf 'n\n' | script -q /dev/null "$BASH" "$HERE/photo.sh" copy "$W/pty/s" "$W/pty/d" >/dev/null 2>&1
        eq "$t tty: n keeps"      "$(cat "$W/pty/d/A.ARW")" old
        printf 'y\n' | script -q /dev/null "$BASH" "$HERE/photo.sh" copy "$W/pty/s" "$W/pty/d" >/dev/null 2>&1
        eq "$t tty: y replaces"   "$(cat "$W/pty/d/A.ARW")" new
    elif [[ -n "${PHOTO_TESTS_REQUIRE_PTY:-}" ]]; then bad_ "$t tty: no pseudo-terminal"
    else printf '  (skipped %s terminal tests: no pseudo-terminal)\n' "$t"; fi

    PATH="$SAVED_PATH"
done

printf '\n%s\n' "----------------------"
if [[ "$F" -eq 0 ]]; then printf 'All %d passed (bash %s; rsync: %s).\n' "$P" "$BASH_VERSION" "${IMPLS[*]}"; exit 0
else printf '%d passed, %d FAILED: %s\n' "$P" "$F" "${FN[*]}"; exit 1; fi
