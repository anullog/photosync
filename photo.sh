#!/usr/bin/env bash
# photo.sh — field copy operations, each fast and safe. No flow, no state.
# macOS / stock bash 3.2. Needs rsync: Homebrew rsync 3.x or macOS's built-in openrsync.
#
#   photo.sh copy   SRC DST [-c]    additive copy (never deletes on DST, asks before replacing)
#   photo.sh sync   SRC DST         mirror SRC→DST (asks before deleting or replacing on DST)
#   photo.sh verify SRC DST         checksum-compare every SRC file against DST
#
# "Safe" = rsync verifies every file's whole-file checksum in transit and only gives a file its
# real name once it is complete, so an interrupted run never leaves a truncated photo on DST.
# `copy -c` and `verify` then compare checksums of SRC and DST. Right after a copy, DST is mostly
# read back from the macOS memory cache, not the disk: before you wipe a card, eject and
# reconnect DST, then run `verify`. copy/sync are incremental: unchanged files (size+mtime) are skipped.

set -euo pipefail
IFS=$'\n\t'

if [[ -t 1 ]]; then BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; NC=$'\e[0m'
else BOLD=''; RED=''; GRN=''; YLW=''; NC=''; fi
say()  { printf '%s%s%s\n' "$BOLD" "$*" "$NC"; }
ok()   { printf '%s✓ %s%s\n' "$GRN" "$*" "$NC"; }
warn() { printf '%s⚠ %s%s\n' "$YLW" "$*" "$NC" >&2; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

EXCLUDES=( --exclude='.DS_Store' --exclude='._*' --exclude='.Spotlight-V100'
           --exclude='.Trashes' --exclude='.fseventsd' --exclude='.TemporaryItems'
           --exclude='.DocumentRevisions-V100' --exclude='System Volume Information'
           --exclude='$RECYCLE.BIN' )

# PROG/CKSUM are expanded unquoted on purpose: empty → no argument (bash 3.2 has no safe empty arrays under set -u)
PROG="--progress"; CKSUM=""
_ver_ge() { local M m; [[ "$3" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
            M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
            [[ "$M" -gt "$1" || ( "$M" -eq "$1" && "$m" -ge "$2" ) ]]; }
_rsync_caps() {
    local vstr v=""
    vstr="$(rsync --version 2>/dev/null)" || true
    [[ "$vstr" =~ version[[:space:]]+([0-9]+\.[0-9]+) ]] && v="${BASH_REMATCH[1]}"
    _ver_ge 3 1 "$v" && PROG="--info=progress2"
    [[ "$vstr" == *xxh128* ]] && CKSUM="--checksum-choice=xxh128"
    return 0
}

# Filters over `rsync -i` lines on stdin. Only the leading 2–3 code chars are read, so they work
# for rsync 3.x (11-char codes) and openrsync (9-char codes) alike. Output is plain paths.
# _problems: in a `-rcn` dry run rsync lists a file only if it is missing on DST or its content differs.
_problems()     { awk '/^[<>c]f/ { k = (substr($0,3,1) == "+") ? "missing" : "differs"
                                   sub(/^[^ ]+ +/, ""); print k "  " $0 }'; }
_deletions()    { awk '/^\*deleting/ && !/\/$/ { sub(/^[^ ]+ +/, ""); print }'; }
_replacements() { awk '/^[<>c]f/ && substr($0,3,1) != "+" { sub(/^[^ ]+ +/, ""); print }'; }
_list()         { awk 'NR<=20 { print "    " $0 } END { if (NR>20) print "    … and " NR-20 " more" }'; }
_n()            { [[ -z "$1" ]] && echo 0 || printf '%s\n' "$1" | awk 'END { print NR }'; }

_need_dir()  { [[ -d "$1" ]] || die "Not a directory: $1"; }
# true if DIR holds a regular file outside hidden/system folders (.fseventsd, .Spotlight-V100, …)
_nonempty()  { [[ -n "$(find -H "$1" -mindepth 1 \( -name '.*' -o -name 'System Volume Information' \
                   -o -name '$RECYCLE.BIN' \) -prune -o -type f -print -quit 2>/dev/null)" ]]; }
_have()      { command -v "$1" >/dev/null 2>&1 || die "$1 not installed."; }
_no_opts()   { local x; for x in "$@"; do [[ "$x" != -* ]] || die "unknown option: $x"; done; }
_confirm()   { local ans; printf '%s [y/N] ' "$1"; IFS= read -r ans || ans=""
               [[ "$ans" == [yY]* ]] || die "aborted"; }

# run rsync; on failure say so instead of exiting silently
_rsync() { local rc=0; rsync "$@" || rc=$?
           [[ "$rc" -eq 0 ]] || die "rsync failed (exit ${rc}): transfer incomplete. Re-run to finish."; }

# dry-run SRC→DST (extra rsync args after the two dirs). Sets PV_DEL / PV_REP to the DST files
# that would be deleted / replaced. Returns rsync's exit code.
PV_DEL=""; PV_REP=""
_preview() {
    local src="$1" dst="$2" out rc=0; shift 2
    out="$(rsync -ai --dry-run --modify-window=2 "$@" "${EXCLUDES[@]}" "${src}/" "${dst}/")" || rc=$?
    PV_DEL="$(printf '%s\n' "$out" | _deletions)"
    PV_REP="$(printf '%s\n' "$out" | _replacements)"
    return "$rc"
}

# checksum compare (copy -c, verify). Prints problem lines; empty = clean.
_verify() {
    local src="$1" dst="$2" out rc=0
    out="$(rsync -rcni ${CKSUM} "${EXCLUDES[@]}" "${src}/" "${dst}/")" || rc=$?
    [[ "$rc" -eq 0 ]] || { printf 'could not compare (rsync exit %s)\n' "$rc"; return 0; }
    printf '%s\n' "$out" | _problems
}

_check() {
    say "verify (checksums) …"
    local p; p="$(_verify "$1" "$2")"
    [[ -z "$p" ]] || { printf '%s\n' "$p" | _list; die "VERIFY FAILED — do not wipe the source."; }
    ok "checksums match: every SRC file is on DST with identical content"
}

cmd_copy() {
    _have rsync
    local verify=0 a=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--verify) verify=1;;
            -*) die "unknown option: $1";;
            *) a+=("$1");;
        esac; shift
    done
    [[ "${#a[@]}" -eq 2 ]] || die "usage: copy SRC DST [-c]"
    local src="${a[0]}" dst="${a[1]}"
    _need_dir "$src"; mkdir -p "$dst"
    say "copy  ${src}  →  ${dst}"
    local rc=0; _preview "$src" "$dst" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        warn "couldn't preview the copy (rsync exit $rc)."
        _confirm "Copy anyway (may replace files on DST)?"
    elif [[ -n "$PV_REP" ]]; then
        warn "$(_n "$PV_REP") file(s) already on DST have a different size or date than SRC and would be REPLACED:"
        printf '%s\n' "$PV_REP" | _list
        _confirm "Replace them?"
    fi
    _rsync -a --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    if [[ "$verify" -eq 1 ]]; then
        _check "$src" "$dst"
        say "Before wiping the card: eject + reconnect DST, then run  photo.sh verify SRC DST  (reads DST from disk)."
    fi
    ok "copy done"
}

cmd_sync() {
    _have rsync
    _no_opts "$@"
    [[ $# -eq 2 ]] || die "usage: sync SRC DST"
    local src="$1" dst="$2"
    _need_dir "$src"; mkdir -p "$dst"
    _nonempty "$src" || die "Refusing to mirror: SRC has no files (would wipe DST)."
    say "sync  ${src}  →  ${dst}"
    local rc=0; _preview "$src" "$dst" --delete || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        warn "couldn't preview the mirror (rsync exit $rc)."
        _confirm "Mirror anyway (may delete or replace files on DST)?"
    elif [[ -n "${PV_DEL}${PV_REP}" ]]; then
        [[ -z "$PV_DEL" ]] || { warn "$(_n "$PV_DEL") file(s) on DST will be DELETED:"; printf '%s\n' "$PV_DEL" | _list; }
        [[ -z "$PV_REP" ]] || { warn "$(_n "$PV_REP") file(s) on DST will be REPLACED:"; printf '%s\n' "$PV_REP" | _list; }
        _confirm "Proceed?"
    fi
    _rsync -a --delete --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    ok "sync done"
}

cmd_verify() {
    _have rsync
    _no_opts "$@"
    [[ $# -eq 2 ]] || die "usage: verify SRC DST"
    _need_dir "$1"; _need_dir "$2"
    say "verify  $1  ↔  $2"
    _check "$1" "$2"
}

usage() {
    cat <<EOF
${BOLD}photo.sh${NC} — field photo copy

  photo.sh copy   SRC DST [-c]    additive copy, never deletes on DST; asks before replacing.
                                  -c = checksum-compare SRC and DST afterwards.
  photo.sh sync   SRC DST         mirror SRC→DST; asks before deleting or replacing on DST.
  photo.sh verify SRC DST         checksum-compare SRC and DST. Before wiping a card, eject and
                                  reconnect DST first so DST is read from the disk.

SRC/DST are directories; copy/sync move the CONTENTS of SRC into DST.
EOF
}

_main() {
    [[ $# -ge 1 ]] || { usage; exit 1; }
    local sub="$1"; shift
    case "$sub" in
        copy)   _rsync_caps; cmd_copy "$@";;
        sync)   _rsync_caps; cmd_sync "$@";;
        verify) _rsync_caps; cmd_verify "$@";;
        -h|--help|help) usage;;
        *) usage; die "unknown command: $sub";;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then _main "$@"; fi
