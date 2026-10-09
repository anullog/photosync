#!/usr/bin/env bash
# photo.sh — three field operations, each fast and safe. No flow, no state.
# macOS / stock bash 3.2.  rsync required; rename also needs exiftool.
#
#   photo.sh copy   SRC DST [-c]            additive copy (never deletes on DST)
#   photo.sh sync   SRC DST                 mirror SRC→DST (propagates deletes)
#   photo.sh rename DIR [--shift ±Nh] [--backup]
#
# "Safe" = rsync verifies every file's whole-file checksum in transit and re-sends
# on mismatch, so a finished copy matches the source. It does NOT re-read the written
# bytes back off the medium; `copy -c` adds that readback compare (use it before you
# wipe a card). copy/sync are incremental: unchanged files (size+mtime) are skipped.

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

PROG="--progress"; CKSUM=""
_ver_ge() { local M m; [[ "$3" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
            M="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
            [[ "$M" -gt "$1" || ( "$M" -eq "$1" && "$m" -ge "$2" ) ]]; }
_rsync_caps() {
    local vstr v=""
    vstr="$(rsync --version 2>/dev/null)" || true
    [[ "$vstr" =~ version[[:space:]]+([0-9]+\.[0-9]+) ]] && v="${BASH_REMATCH[1]}"
    _ver_ge 3 1 "$v" && PROG="--info=progress2"
    _ver_ge 3 2 "$v" && CKSUM="--checksum-choice=xxh128"
    return 0
}

# date-shift token for exiftool, from signed hours.  +2 → "-AllDates+=0:0:0 2:0:0"
_shift_token() { local h="$1" op="+=" mag="$1"; [[ "$h" == -* ]] && { op="-="; mag="${h#-}"; }
                 printf -- '-AllDates%s0:0:0 %s:0:0' "$op" "$mag"; }

# read `rsync -i` lines on stdin, print only real content problems (missing/checksum/size)
_problems() { awk '/^[<>c]f/{c=substr($0,1,11);
                   if(substr(c,3,9)=="+++++++++"||substr(c,3,1)=="c"||substr(c,4,1)=="s") print}'; }

_need_dir()  { [[ -d "$1" ]] || die "Not a directory: $1"; }
_nonempty()  { [[ -n "$(find "$1" -type f -print -quit 2>/dev/null)" ]]; }
_have()      { command -v "$1" >/dev/null 2>&1 || die "$1 not installed."; }

# readback checksum compare (copy -c). Prints problem lines; empty = clean.
_verify() {
    local src="$1" dst="$2" out rc=0
    out="$(rsync -rcni --no-owner --no-group ${CKSUM} "${EXCLUDES[@]}" "${src}/" "${dst}/" 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] || { printf 'VERIFY-ERROR: rsync exit %s\n' "$rc"; return 0; }
    printf '%s\n' "$out" | _problems
}

cmd_copy() {
    _have rsync
    local verify=0 a=()
    while [[ $# -gt 0 ]]; do case "$1" in -c|--verify) verify=1;; *) a+=("$1");; esac; shift; done
    [[ "${#a[@]}" -eq 2 ]] || die "usage: copy SRC DST [-c]"
    local src="${a[0]}" dst="${a[1]}"
    _need_dir "$src"; mkdir -p "$dst"
    say "copy  ${src}  →  ${dst}"
    rsync -a --partial --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    if [[ "$verify" -eq 1 ]]; then
        say "verify (readback) …"
        local p; p="$(_verify "$src" "$dst")"
        [[ -z "$p" ]] || { printf '%s\n' "$p" | awk 'NR<=40'; die "VERIFY FAILED — do not wipe the source."; }
        ok "verified byte-for-byte"
    fi
    ok "copy done"
}

cmd_sync() {
    _have rsync
    [[ $# -eq 2 ]] || die "usage: sync SRC DST"
    local src="$1" dst="$2"
    _need_dir "$src"; mkdir -p "$dst"
    _nonempty "$src" || die "Refusing to mirror: SRC has no files (would wipe DST)."
    say "sync  ${src}  →  ${dst}"
    local out rc=0
    out="$(rsync -ai --delete --dry-run --modify-window=2 "${EXCLUDES[@]}" "${src}/" "${dst}/" 2>/dev/null)" || rc=$?
    local del=0
    [[ "$rc" -eq 0 ]] && del="$(printf '%s\n' "$out" | grep -c '\*deleting' || true)"
    if [[ "$rc" -ne 0 ]]; then
        warn "couldn't preview deletions (rsync exit $rc)."
        printf 'Mirror anyway (may delete files on DST)? [y/N] '
        local ans; IFS= read -r ans || ans=""; [[ "$(printf '%s' "$ans" | tr 'A-Z' 'a-z')" == y* ]] || die "aborted"
    elif [[ "$del" -gt 0 ]]; then
        warn "${del} file(s) on DST will be DELETED to match SRC."
        printf 'Proceed? [y/N] '
        local ans; IFS= read -r ans || ans=""; [[ "$(printf '%s' "$ans" | tr 'A-Z' 'a-z')" == y* ]] || die "aborted"
    fi
    rsync -a --delete --partial --modify-window=2 ${PROG} -h "${EXCLUDES[@]}" "${src}/" "${dst}/"
    ok "sync done"
}

cmd_rename() {
    _have exiftool
    local dir="" shift_h="" backup=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --shift) shift; shift_h="${1:-}";;
            --backup) backup=1;;
            -*) die "unknown option: $1";;
            *) dir="$1";;
        esac; shift
    done
    [[ -n "$dir" ]] || die "usage: rename DIR [--shift ±Nh] [--backup]"
    _need_dir "$dir"
    local EXTS=( -ext ARW -ext RAF -ext JPG -ext JPEG )

    if [[ -n "$shift_h" ]]; then
        [[ "$shift_h" =~ ^[+-]?[0-9]+h?$ ]] || die "shift must look like +2h or -3h"
        local tok; tok="$(_shift_token "${shift_h%h}")"
        say "shift dates ${shift_h%h}h …"
        exiftool -q -overwrite_original -P -m "$tok" "${EXTS[@]}" -r "$dir" \
            || warn "exiftool reported issues during shift (continuing)"
    fi
    if [[ "$backup" -eq 1 ]]; then
        local bk="${dir%/}/_metadata_backup_$(date '+%Y%m%d_%H%M%S').json"
        ( cd "$dir" && exiftool -q -j -r . ) > "$bk" 2>/dev/null || true
        ok "metadata backup: $bk"
    fi

    local P='$FileName !~ /^\d{4}-\d\d-\d\d_\d{6}_/'
    say "rename …"
    exiftool -q -overwrite_original -m -r -d "%Y-%m-%d_%H%M%S" \
        -if "$P" -if '$DateTimeOriginal' \
        "-CreateDate<DateTimeOriginal" "-ModifyDate<DateTimeOriginal" "-FileModifyDate<DateTimeOriginal" \
        '-FileName<${DateTimeOriginal}_${FileName}' "${EXTS[@]}" "$dir" 2>/dev/null || true
    exiftool -q -overwrite_original -m -r -d "%Y-%m-%d_%H%M%S" \
        -if "$P" -if 'not $DateTimeOriginal' -if '$CreateDate' \
        '-FileName<${CreateDate}_${FileName}' "${EXTS[@]}" "$dir" 2>/dev/null || true
    exiftool -q -overwrite_original -m -r -d "%Y-%m-%d_%H%M%S" \
        -if "$P" '-FileName<${FileModifyDate}_${FileName}' "${EXTS[@]}" "$dir" 2>/dev/null || true
    ok "rename done (date prefix added; originals recoverable by stripping it)"
}

usage() {
    cat <<EOF
${BOLD}photo.sh${NC} — field photo operations

  photo.sh copy   SRC DST [-c]    additive copy, never deletes on DST. -c = readback verify.
  photo.sh sync   SRC DST         mirror SRC→DST (deletes on DST to match; previews first).
  photo.sh rename DIR [--shift ±Nh] [--backup]
                                  exif-normalise + date-prefix rename, idempotent.

SRC/DST are directories; copy/sync move the CONTENTS of SRC into DST.
EOF
}

_main() {
    [[ $# -ge 1 ]] || { usage; exit 1; }
    local sub="$1"; shift || true
    case "$sub" in
        copy)   _rsync_caps; cmd_copy "$@";;
        sync)   _rsync_caps; cmd_sync "$@";;
        rename) cmd_rename "$@";;
        -h|--help|help) usage;;
        *) usage; die "unknown command: $sub";;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then _main "$@"; fi
