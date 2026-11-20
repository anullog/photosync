#!/usr/bin/env bash
# photo.sh — safe copy, mirror and verify for photo folders and memory cards. No state, no config.
# macOS, stock bash 3.2. Needs rsync: macOS's built-in openrsync works; Homebrew rsync 3.x adds a
# single overall progress bar.
#
#   photo.sh copy   SRC DST [-c]    copy SRC into DST. Never deletes on DST; asks before replacing.
#   photo.sh sync   SRC DST         make DST an exact mirror of SRC; asks before deleting or replacing.
#   photo.sh verify SRC DST         check that every SRC file is on DST with identical content.
#
# How it stays safe:
#  - copy and sync start with a dry run. Every file on DST that would be replaced or deleted is listed
#    and needs an answer typed on the terminal. The real run is held to what was shown: the dry run
#    is repeated after the question, deletions are capped with --max-delete, and a copy that was not
#    allowed to replace anything runs with --ignore-existing.
#  - rsync checksums each file in transit and gives it its real name only once it is complete, so an
#    interrupted run never leaves a truncated photo under its real name.
#  - `copy -c` and `verify` compare content checksums. Right after a copy, DST is mostly read back
#    from the macOS memory cache: before wiping a card, eject and reconnect DST, then run `verify`.

# Must be POSIX sh syntax: zsh/sh read this line before any bash-only syntax below. `return` covers
# being sourced, so the caller's shell stays open.
[ -n "${BASH_VERSION:-}" ] || { echo "photo.sh: needs bash. Run it as ./photo.sh or: bash photo.sh" >&2; return 2 2>/dev/null; exit 2; }

VERSION="1.0.0"

# Colours per stream (say/ok → stdout, warn/die → stderr); NO_COLOR turns them off.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then BOLD=$'\e[1m'; GRN=$'\e[32m'; NC=$'\e[0m'; else BOLD=''; GRN=''; NC=''; fi
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then RED=$'\e[31m'; YLW=$'\e[33m'; NC2=$'\e[0m'; else RED=''; YLW=''; NC2=''; fi
say()  { printf '%s%s%s\n' "$BOLD" "$1" "$NC"; }
ok()   { printf '%s✓ %s%s\n' "$GRN" "$1" "$NC"; }
warn() { printf '%s⚠ %s%s\n' "$YLW" "$1" "$NC2" >&2; }
die()  { printf '%s✗ %s%s\n' "$RED" "$1" "$NC2" >&2; exit "${2:-1}"; }

# Card and macOS system clutter: never copied, deleted or compared.
JUNK=( '.DS_Store' '._*' '.Spotlight-V100' '.Trashes' '.fseventsd' '.TemporaryItems'
       '.DocumentRevisions-V100' 'System Volume Information' '$RECYCLE.BIN' )
FIND_JUNK=(); for _p in "${JUNK[@]}"; do FIND_JUNK+=( -o -name "$_p" ); done; unset _p

# Set by _rsync_caps for the rsync in PATH. PROG is expanded unquoted on purpose: empty gives no
# argument (bash 3.2 has no safe empty arrays under set -u); its two words are split on IFS's \n.
# IW is the width of rsync's itemize codes: 11 for rsync 3.x, 9 for openrsync and rsync 2.x.
PROG=""; IW=11; OPENRSYNC=0
_plain_excludes() { local p; EXCLUDES=(); for p in "${JUNK[@]}"; do EXCLUDES+=( "--exclude=$p" ); done; }
_plain_excludes
_ver_ge() { local M m; [[ "$3" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
            M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
            [[ "$M" -gt "$1" || ( "$M" -eq "$1" && "$m" -ge "$2" ) ]]; }
_rsync_caps() {
    local vstr v="" rs3=0 p
    PROG=""; IW=9; OPENRSYNC=0; _plain_excludes
    vstr="$(rsync --version 2>/dev/null)" || true
    [[ "$vstr" =~ version[[:space:]]+v?([0-9]+\.[0-9]+) ]] && v="${BASH_REMATCH[1]}"
    if [[ "$vstr" == *openrsync* ]]; then OPENRSYNC=1; elif _ver_ge 3 0 "$v"; then rs3=1; IW=11; fi
    if [[ -t 1 ]]; then
        # one bar for the whole run; building the full file list first keeps its % from jumping back
        if [[ "$rs3" -eq 1 ]] && _ver_ge 3 1 "$v"; then PROG=$'--info=progress2\n--no-inc-recursive'
        else PROG="--progress"; fi
    fi
    # Perishable excludes (rsync 3.x, openrsync): clutter inside a folder that sync deletes no longer
    # keeps that folder alive. Probed, because older rsyncs reject the modifier.
    if rsync -n -r --filter='-p x' /var/empty/ /var/empty/ >/dev/null 2>&1; then
        EXCLUDES=(); for p in "${JUNK[@]}"; do EXCLUDES+=( "--filter=-p $p" ); done
    fi
    return 0
}

# ---- reading rsync's change list -----------------------------------------------------------------
# The filters read `%i %n` lines (itemize code, space, name) on stdin and print one path per line.
# They run byte-wise (LC_ALL=C): in a UTF-8 locale macOS awk aborts on the partly escaped names
# openrsync prints, and a filter that dies must never look like "nothing to delete". rsync shows
# unprintable bytes as \#ooo: un() turns the high ones (>= 0x80, i.e. UTF-8) back into bytes, so
# names print as they are, while control characters stay escaped; benc() rewrites every escape for
# bash's printf %b, to rebuild the exact name on disk. Only the first 2–3 code characters are read,
# so the filters work for rsync 3.x (11-char codes) and openrsync (9-char codes) alike.
_AWK_LIB='
function un(s,   o, i, c) {
    o = ""
    while ((i = index(s, "\\#")) > 0) {
        c = substr(s, i + 2, 3)
        if (c ~ /^[23][0-7][0-7]$/) {
            o = o substr(s, 1, i - 1) sprintf("%c", substr(c, 1, 1) * 64 + substr(c, 2, 1) * 8 + substr(c, 3, 1))
            s = substr(s, i + 5)
        } else { o = o substr(s, 1, i + 1); s = substr(s, i + 2) }
    }
    return o s
}
function benc(s,   o, i) {
    o = ""
    while ((i = index(s, "\\")) > 0) {
        if (substr(s, i + 1, 4) ~ /^#[0-3][0-7][0-7]$/) { o = o substr(s, 1, i - 1) "\\0" substr(s, i + 2, 3); s = substr(s, i + 5) }
        else { o = o substr(s, 1, i) "\\"; s = substr(s, i + 1) }
    }
    return o s
}
function name() { return un(substr($0, index($0, " ") + 1)) }   # change codes never contain a space
'
# verify: in a `-rcn` dry run a file shows up as [<>c]f only if it is missing on DST or its content
# differs (openrsync also lists same-content files with another date, as .f..T, which are skipped).
_problems() { LC_ALL=C awk "$_AWK_LIB"'/^[<>c]f/ { print ((substr($0, 3, 1) == "+") ? "missing" : "differs") "  " name() }'; }
# existing DST files that would be overwritten (rsync 3 also lists symlinks whose target changes)
_replacements() { LC_ALL=C awk "$_AWK_LIB"'(/^[<>c]f/ || /^cL/) && substr($0, 3, 1) != "+" { print name() }'; }
# New items (code +) whose path already holds something else on DST. Prints "R<path>" when DST has a
# file or symlink there (both rsyncs silently delete it to put a folder or link in its place, with or
# without --delete) and "W<path>" when DST has a folder where SRC has a file or link. DST is $1.
_typechg() {
    local dst="$1" p f t
    LC_ALL=C awk "$_AWK_LIB"'/^[<>ch.][fdLDS]\+/ {
            r = substr($0, index($0, " ") + 1); p = un(r)
            d = (p ~ /\/$/); sub(/\/$/, "", p); sub(/\/$/, "", r)
            par = p; if (!sub(/\/[^\/]*$/, "", par)) par = "."
            if (par in nd) { if (d) nd[p] = 1; next }        # inside a new folder: cannot exist yet
            if (d) nd[p] = 1
            if (index(r, "\\")) print "/" benc(r)             # exact name for the lookup (paths never start with /)
            print substr($0, 2, 1) p }' |
    while IFS= read -r p; do
        f=""
        if [[ "$p" == /* ]]; then printf -v f '%b' "${p#/}"; IFS= read -r p || break; fi
        t="${p:0:1}"; p="${p:1}"; [[ -n "$f" ]] || f="$p"
        if [[ -L "$dst/$f" || ( -e "$dst/$f" && ! -d "$dst/$f" ) ]]; then printf 'R%s\n' "$p"
        elif [[ ( "$t" == f || "$t" == L ) && -d "$dst/$f" ]]; then printf 'W%s\n' "$p"; fi
    done
}
# openrsync neither lists nor counts a symlink whose target changed (rsync 3 shows cLc…): compare them
_relinks() {  # SRC DST
    local l
    { (CDPATH='' cd "$1" && find . \( -false "${FIND_JUNK[@]}" \) -prune -o -type l -print) 2>/dev/null || true; } |
    while IFS= read -r l; do
        l="${l#./}"
        if [[ -L "$2/$l" && "$(readlink "$1/$l")" != "$(readlink "$2/$l")" ]]; then printf '%s\n' "$l"; fi
    done
}
# DST files a --delete run removes. Folders and clutter are left out (they hold no photos), and
# openrsync can list a file twice.
_deletions() { LC_ALL=C awk -v w="$IW" -v junk="$(IFS=/; printf '%s' "${JUNK[*]}")" "$_AWK_LIB"'
    BEGIN { nj = split(junk, J, "/") }                    # "/" never occurs in a name, "\n" may not be in -v
    function isjunk(p,   n, C, i, j, c) {
        n = split(p, C, "/")
        for (i = 1; i <= n; i++) for (j = 1; j <= nj; j++) {
            c = J[j]
            if (c ~ /\*$/) { if (index(C[i], substr(c, 1, length(c) - 1)) == 1) return 1 }
            else if (C[i] == c) return 1
        }
        return 0
    }
    /^\*deleting/ && !/\/$/ { p = un(substr($0, w + 2)); if (!isjunk(p) && !seen[p]++) print p }'; }
# Up to 20 paths, indented. C1 controls and bidi overrides are masked so a name can't pose as another.
_list() { LC_ALL=C sed $'s/\xc2[\x80-\x9f]/?/g; s/\xe2\x80[\xaa-\xae]/?/g; s/\xe2\x81[\xa6-\xa9]/?/g' |
          LC_ALL=C awk 'NR <= 20 { print "    " $0 } END { if (NR > 20) print "    … and " NR - 20 " more" }'; }
_n() { if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | LC_ALL=C awk 'END { print NR }'; fi; }

# ---- paths ---------------------------------------------------------------------------------------
_need_dir() { [[ -d "$1" ]] || die "Not a directory: $1"; }
_not_file() { [[ ! -e "$1" || -d "$1" ]] || die "Not a directory: $1"; }
_have()     { command -v "$1" >/dev/null 2>&1 || die "$1 not installed."; }
# rsync reads "a:b" as host:path when the ':' comes before any '/'. Anchor relative paths with ./
# so a folder like "shoot 10:30" (or one named "-x") stays a local folder.
_local() { case "$1" in /*) printf '%s' "$1";; *) printf './%s' "$1";; esac; }
# true if DIR holds a regular file outside hidden/system folders (.fseventsd, .Spotlight-V100, …)
_nonempty() { [[ -n "$(find -H "$1" -mindepth 1 \( -name '.*' -o -name 'System Volume Information' \
                  -o -name '$RECYCLE.BIN' \) -prune -o -type f -print -quit 2>/dev/null)" ]]; }
# number of files in DIR that verify compares (clutter left out, as in EXCLUDES)
_count_files() { { find -H "$1" -mindepth 1 \( -false "${FIND_JUNK[@]}" \) -prune -o -type f -print 2>/dev/null || true; } |
                 LC_ALL=C awk 'END { print NR }'; }
# Physical path of a folder that may not exist yet: resolve its deepest existing ancestor. The
# system pwd returns the on-disk spelling, so case-only differences still compare equal. '.' or
# '..' below a missing folder can't be resolved before it exists, so that fails.
_real() {
    local d="$1" rest="" r
    while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
    while [[ ! -d "$d" ]]; do
        case "${d##*/}" in .|..) return 1;; esac
        rest="/${d##*/}$rest"; d="$(dirname -- "$d")"
    done
    r="$(CDPATH='' cd -P -- "$d" 2>/dev/null && /bin/pwd -P)" || return 1
    printf '%s%s' "${r%/}" "$rest"
}
# Refuse SRC/DST combinations that destroy data: the same folder, DST inside SRC (copies DST into
# itself on every run) and, for sync, SRC inside DST (the mirror would delete SRC itself).
_no_overlap() {  # MODE SRC DST
    local s d
    s="$(_real "$2")" && d="$(_real "$3")" || die "Cannot resolve the path of $2 or $3"
    s="${s%/}/"; d="${d%/}/"
    [[ "$s" != "$d" ]] || die "SRC and DST are the same folder."
    [[ "$d" != "$s"* ]] || die "DST is inside SRC: every run would copy DST into itself."
    [[ "$1" != sync || "$s" != "$d"* ]] || die "SRC is inside DST: the mirror would delete SRC itself."
}

# ---- asking --------------------------------------------------------------------------------------
# Ask on the terminal; the answer goes to ANS. Without a terminal on stdin the answer is empty, so
# piped or redirected input never confirms anything. PHOTO_SH_TEST_ANSWER stands in for the
# terminal in photo_tests.sh only.
ANS=""
_ask() {
    ANS=""; printf '%s ' "$1" >&2
    if [[ -t 0 ]]; then IFS= read -r ANS || ANS=""
    elif [[ -n "${PHOTO_SH_TEST_ANSWER+x}" ]]; then ANS="$PHOTO_SH_TEST_ANSWER"; printf '%s\n' "$ANS" >&2
    else printf '(no terminal to answer from)\n' >&2; fi
}
_confirm() { _ask "$1 [y/N]"; case "$ANS" in y|Y|yes|Yes|YES) ;; *) die "aborted: nothing changed";; esac; }
# Ask before losing N files on DST (deleted or replaced). When N is more than the list shows and more
# than half the files on DST, y is not enough: the number has to be typed, because that is usually
# the wrong SRC or DST (or a second card with the same file names).
_guard() {  # N QUESTION DST
    local n="$1" total=0
    [[ "$n" -le 20 ]] || total="$(_count_files "$3")"
    if [[ "$n" -gt 20 && $((n * 2)) -gt "$total" ]]; then
        warn "That is $n of the $total files on DST. Check that SRC and DST are the folders you meant."
        _ask "To go ahead, type the number $n:"
        [[ "$ANS" == "$n" ]] || die "aborted: nothing changed"
    else
        _confirm "$2"
    fi
}

# ---- rsync runs ----------------------------------------------------------------------------------
# run rsync for real; on failure say what it means instead of exiting silently
_rsync() {
    local rc=0; rsync "$@" || rc=$?
    case "$rc" in
        0)  ;;
        25) die "rsync stopped deleting at the previewed count: DST changed after the preview, so some deletions may differ from the list. Re-run to see the new list.";;
        *)  die "rsync failed (exit ${rc}). Files already copied are complete; fix the errors above, then re-run.";;
    esac
}

# Dry-run SRC→DST with the real run's options plus extra args. Sets PV_DEL / PV_REP (DST files that
# would be deleted / replaced, type changes included), PV_WAY (DST folders where SRC has a file or
# link), PV_OUT (all change lines, sorted, to spot changes later), PV_NDEL (all *deleting lines,
# folders and clutter included, for --max-delete) and PV_ANY (number of changes). Returns rsync's
# exit code, or 98 when its output could not be read.
PV_DEL=""; PV_REP=""; PV_WAY=""; PV_OUT=""; PV_NDEL=0; PV_ANY=0
_preview() {
    local src="$1" dst="$2" out rc=0 bad=0 n tc lk nl=$'\n'; shift 2
    out="$(rsync -a --out-format='%i %n' --dry-run --modify-window=2 "$@" "${EXCLUDES[@]}" "${src}/" "${dst}/")" || rc=$?
    PV_DEL="$(printf '%s\n' "$out" | _deletions)" || bad=1
    PV_REP="$(printf '%s\n' "$out" | _replacements)" || bad=1
    tc="$(printf '%s\n' "$out" | _typechg "$dst")" || bad=1
    PV_WAY="$(printf '%s\n' "$tc" | LC_ALL=C sed -n 's/^W//p')"
    tc="$(printf '%s\n' "$tc" | LC_ALL=C sed -n 's/^[RW]//p')"
    [[ -z "$tc" ]] || PV_REP="${PV_REP}${PV_REP:+$nl}${tc}"
    PV_OUT="$(printf '%s\n' "$out" | LC_ALL=C awk '/^([<>ch]|\*deleting)/' | LC_ALL=C sort)" || bad=1
    n="$(printf '%s\n' "$out" | LC_ALL=C awk '/^\*deleting/ { d++ } /^([<>ch]|\*deleting)/ { a++ } END { print d + 0, a + 0 }')" || bad=1
    [[ "$n" =~ ^[0-9]+[[:space:]][0-9]+$ ]] || { n="0 1"; bad=1; }
    PV_NDEL="${n% *}"; PV_ANY="${n#* }"
    if [[ "$OPENRSYNC" -eq 1 ]]; then
        lk="$(_relinks "$src" "$dst")"
        if [[ -n "$lk" ]]; then PV_REP="${PV_REP}${PV_REP:+$nl}${lk}"; PV_OUT="${PV_OUT}${nl}${lk}"; PV_ANY=$((PV_ANY + 1)); fi
    fi
    if [[ "$bad" -ne 0 ]]; then rc=98; fi
    return "$rc"
}
_snap() { printf '%s\n--\n%s\n--\n%s\n--\n%s' "$PV_DEL" "$PV_REP" "$PV_NDEL" "$PV_OUT"; }
# after a question: dry-run again and stop if SRC or DST changed while it was open
_recheck() {  # RC-OF-FIRST-PREVIEW SRC DST [extra rsync args]
    local want="$1" before rc=0; shift; before="$(_snap)"
    _preview "$@" || rc=$?
    [[ "$rc" -eq "$want" ]] || die "couldn't re-check DST (rsync exit $rc): nothing changed."
    [[ "$(_snap)" == "$before" ]] || die "SRC or DST changed while waiting for your answer: nothing changed. Re-run."
}
# what the preview found on DST, on stderr next to the question. $1 = "at least " or "".
_show() {
    [[ -z "$PV_DEL" ]] || { warn "$1$(_n "$PV_DEL") file(s) on DST will be DELETED:"; printf '%s\n' "$PV_DEL" | _list >&2; }
    [[ -z "$PV_REP" ]] || { warn "$1$(_n "$PV_REP") file(s) on DST will be REPLACED (different size or date, or something else goes in their place):"
                            printf '%s\n' "$PV_REP" | _list >&2; }
}
# the preview showed rsync errors: what was asked about may not be everything
_preview_errors() { die "the preview reported errors (see above), so this run may be incomplete. Fix them and re-run$1."; }

# checksum compare (copy -c, verify). Prints problem lines; empty = clean.
_verify() {
    local out rc=0 p nl=$'\n'
    out="$(rsync -rcni "${EXCLUDES[@]}" "${1}/" "${2}/")" || rc=$?
    p="$(printf '%s\n' "$out" | _problems)" || p="${p}${p:+$nl}could not read rsync's output"
    [[ "$rc" -eq 0 ]] || p="${p}${p:+$nl}could not compare everything (rsync exit ${rc})"
    printf '%s' "$p"
}
_check() {
    local n p; n="$(_count_files "$1")"
    [[ "$n" -gt 0 ]] || die "SRC has no files: nothing to verify."
    say "verify (checksums) …"
    p="$(_verify "$1" "$2")"
    if [[ -n "$p" ]]; then printf '%s\n' "$p" | _list; die "VERIFY FAILED — do not wipe the source."; fi
    ok "checksums match: all $n SRC files are on DST with identical content"
}

# ---- commands ------------------------------------------------------------------------------------
# Parse "[-c] [--] SRC DST" for command $1. Sets A1, A2, OPT_C.
A1=""; A2=""; OPT_C=0
_args() {
    local cmd="$1" n=0 x; shift; OPT_C=0; A1=""; A2=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --) shift; break;;
            -h|--help) usage; exit 0;;
            -c|--verify) [[ "$cmd" == copy ]] || die "unknown option: $1" 2; OPT_C=1;;
            -?*) die "unknown option: $1" 2;;
            *) _arg "$1";;
        esac
        shift
    done
    for x in "$@"; do _arg "$x"; done
    [[ "$n" -eq 2 ]] || { [[ "$cmd" == copy ]] && die "usage: photo.sh copy SRC DST [-c]" 2; die "usage: photo.sh $cmd SRC DST" 2; }
}
_arg() {  # one positional argument for _args (uses its local n)
    [[ -n "$1" ]] || die "empty path argument" 2
    n=$((n + 1)); case "$n" in 1) A1="$1";; 2) A2="$1";; esac
}

cmd_copy() {
    _args copy "$@"; _have rsync; _rsync_caps
    local src dst rc=0 run=1 keep="--ignore-existing" pre=""
    src="$(_local "$A1")"; dst="$(_local "$A2")"
    _need_dir "$src"; _not_file "$dst"; _no_overlap copy "$src" "$dst"
    say "copy  ${src}  →  ${dst}"
    if [[ -d "$dst" ]]; then
        _preview "$src" "$dst" || rc=$?
        [[ "$rc" -ne 98 ]] || die "couldn't read rsync's preview output: nothing changed."
        if [[ -n "$PV_WAY" ]]; then
            warn "$(_n "$PV_WAY") folder(s) on DST are where SRC has a file or link, so copy can't put those there:"
            printf '%s\n' "$PV_WAY" | _list >&2
            die "Move or rename those folders on DST, then re-run: nothing changed."
        fi
        if [[ "$rc" -ne 0 ]]; then pre="at least "; warn "couldn't fully preview the copy (rsync exit $rc): the list below may be incomplete."; fi
        if [[ -n "$PV_REP" ]]; then
            _show "$pre"
            warn "If these are different photos with the same names, answer N and copy into a new folder."
            _guard "$(_n "$PV_REP")" "Replace them?" "$dst"
            _recheck "$rc" "$src" "$dst"; keep=""
        elif [[ "$rc" -ne 0 ]]; then
            _confirm "Copy anyway? Files already on DST are left as they are."
            _recheck "$rc" "$src" "$dst"
        elif [[ "$PV_ANY" -eq 0 ]]; then
            ok "nothing to copy: DST already has every SRC file"; run=0
        fi
    fi
    if [[ "$run" -eq 1 ]]; then
        mkdir -p -- "$dst"
        _rsync -a ${keep} --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    fi
    [[ "$rc" -eq 0 ]] || _preview_errors ", then check with  photo.sh verify SRC DST"
    if [[ "$OPT_C" -eq 1 ]]; then
        _check "$src" "$dst"
        say "Before wiping the card: eject and reconnect DST (internal disk: run 'sudo purge'), then run  photo.sh verify SRC DST"
    fi
    ok "copy done"
}

cmd_sync() {
    _args sync "$@"; _have rsync; _rsync_caps
    local src dst rc=0 run=1 del="" pre="" q="Proceed?"
    src="$(_local "$A1")"; dst="$(_local "$A2")"
    _need_dir "$src"; _not_file "$dst"; _no_overlap sync "$src" "$dst"
    _nonempty "$src" || die "Refusing to mirror: SRC has no files (it would wipe DST)."
    say "sync  ${src}  →  ${dst}"
    if [[ -d "$dst" ]]; then
        _preview "$src" "$dst" --delete || rc=$?
        [[ "$rc" -ne 98 ]] || die "couldn't read rsync's preview output: nothing changed."
        if [[ "$rc" -ne 0 ]]; then
            pre="at least "; q="Mirror anyway?"
            warn "couldn't fully preview the mirror (rsync exit $rc): the lists below may be incomplete."
        fi
        if [[ "$rc" -ne 0 || -n "${PV_DEL}${PV_REP}" ]]; then
            _show "$pre"
            _guard $(( $(_n "$PV_DEL") + $(_n "$PV_REP") )) "$q" "$dst"
            _nonempty "$src" || die "Refusing to mirror: SRC has no files (it would wipe DST)."
            _recheck "$rc" "$src" "$dst" --delete
        elif [[ "$PV_ANY" -eq 0 ]]; then
            ok "nothing to do: DST already mirrors SRC"; run=0
        fi
        # Hold the real run to the preview: no --delete when it found nothing to delete, otherwise at
        # most that many. Never --max-delete=0: openrsync reads it as "unlimited".
        if [[ "$PV_NDEL" -gt 0 ]]; then del=$'--delete\n--max-delete='"$PV_NDEL"; fi
    fi
    if [[ "$run" -eq 1 ]]; then
        mkdir -p -- "$dst"
        _rsync -a ${del} --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    fi
    [[ "$rc" -eq 0 ]] || _preview_errors ""
    ok "sync done"
}

cmd_verify() {
    _args verify "$@"; _have rsync; _rsync_caps
    local src dst
    src="$(_local "$A1")"; dst="$(_local "$A2")"
    _need_dir "$src"; _need_dir "$dst"
    [[ ! "$src" -ef "$dst" ]] || die "SRC and DST are the same folder: nothing to compare."
    say "verify  ${src}  ↔  ${dst}"
    _check "$src" "$dst"
}

usage() {
    cat <<'EOF'
photo.sh — safe copy, mirror and verify for photo folders and memory cards

  photo.sh copy   SRC DST [-c]   copy SRC into DST. Never deletes on DST; asks before replacing.
                                 -c, --verify: afterwards, checksum-compare SRC and DST.
  photo.sh sync   SRC DST        make DST an exact mirror of SRC; asks before deleting or replacing.
  photo.sh verify SRC DST        check that every SRC file is on DST with identical content
                                 (extra files on DST are not reported).

SRC and DST are folders; copy and sync put the CONTENTS of SRC into DST, which is created if needed.
Before wiping a card, eject and reconnect DST (internal disk: run 'sudo purge'), then run verify,
so DST is read from the disk rather than from memory.

Exit status: 0 done, 1 failed or aborted, 2 usage error.   photo.sh --version shows the version.
EOF
}

_main() {
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    local sub="$1"; shift
    case "$sub" in
        copy|sync|verify) "cmd_$sub" "$@";;
        -h|--help|help)   usage;;
        -V|--version)     printf 'photo.sh %s\n' "$VERSION";;
        *)                usage >&2; die "unknown command: $sub" 2;;
    esac
}

# Strict mode only when run, not when sourced (photo_tests.sh sources this file for unit tests).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    set -euo pipefail; IFS=$'\n\t'
    _main "$@"
fi
