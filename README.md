# photosync

`photo.sh` is a small macOS script for getting photos off memory cards safely in the field.
It wraps `rsync` with checks that stop you from losing files: it previews what would change,
asks before replacing or deleting anything, and can checksum-verify a copy before you wipe the card.

No state, no config, no database. Each command is one self-contained operation.

## Commands

| Command | What it does |
|---|---|
| `photo.sh copy SRC DST` | Copies everything from `SRC` into `DST`. Never deletes on `DST`. Asks before replacing a file that is already there with a different size or date. |
| `photo.sh copy SRC DST -c` | Same, then compares checksums of every file on `SRC` and `DST` (`--verify` also works). |
| `photo.sh sync SRC DST` | Makes `DST` a mirror of the files and folders in `SRC`. Lists the files it would delete or replace on `DST` and asks first. |
| `photo.sh verify SRC DST` | Checks that every file on `SRC` is on `DST` with identical content. Changes nothing. Extra files on `DST` are not reported. |

`SRC` and `DST` are folders. The *contents* of `SRC` go into `DST` (no extra `SRC` folder is created).
`DST` is created if it does not exist. Finder tags, other extended attributes and creation dates are
not copied. Symbolic links are copied as links, not as the files they point to.

Exit status: `0` done, `1` failed or aborted, `2` usage error. `photo.sh --help` and `photo.sh --version`
work as usual.

## Requirements

- macOS with the stock `bash` (3.2). Nothing else to install.
- `rsync`: the one built into macOS works. [Homebrew](https://brew.sh) `rsync` 3.x is optional and adds
  a single overall progress bar (`brew install rsync`).

## Install

```bash
git clone https://github.com/anullog/photosync.git
cd photosync
```

Optional, to run it as `photo.sh` from anywhere:

```bash
sudo mkdir -p /usr/local/bin && sudo ln -s "$PWD/photo.sh" /usr/local/bin/photo.sh
```

## Offloading a card safely

Copy the whole card, not just `DCIM`: some cameras keep video elsewhere (Sony, for example, under
`PRIVATE/M4ROOT`). Card system folders are skipped automatically. Give each card its own folder, so
two cards with the same file names (`DSC00001.ARW`, …) never collide.

1. Copy and verify:
   ```bash
   photo.sh copy /Volumes/CARD /Volumes/PhotoSSD/2026-10-09-shoot/card1 -c
   ```
2. Eject the destination drive and plug it back in. Right after a copy, macOS serves most of the
   files from memory, so step 1's check does not prove the data reached the disk.
   If the destination is the internal disk, run `sudo purge` instead.
3. Verify again, now reading from the disk:
   ```bash
   photo.sh verify /Volumes/CARD /Volumes/PhotoSSD/2026-10-09-shoot/card1
   ```
4. Only if step 3's `verify` prints `checksums match`, format the card in the camera. Step 1 prints
   the same words, but that check read `DST` partly from memory.

`verify` prints how many files it compared (`all 412 SRC files are on DST …`), so a wrong or
half-empty `SRC` stands out. If verification fails, the script lists the problem files as `missing`
or `differs` (first 20, plus a count) and exits with `VERIFY FAILED — do not wipe the source.`
Re-running the same `copy` fills in `missing` files, but it may skip a `differs` file whose size and
date already match: copy the card into a new, empty folder (e.g. `card1-again`) and verify that one.

## Other examples

Back up a photo library to an external drive, keeping its files and folders identical:

```bash
photo.sh sync ~/Pictures/Library /Volumes/Backup/Library
```

Offload a second card from the same shoot (re-running any copy is cheap: unchanged files are skipped):

```bash
photo.sh copy /Volumes/CARD2 /Volumes/PhotoSSD/2026-10-09-shoot/card2 -c
```

## How it keeps your files safe

- **Asks before destroying anything.** Every `copy` and `sync` starts with a dry run. If any file on
  `DST` would be replaced or deleted (including a file that a folder or link would take the place of),
  you see the list (first 20, plus a count) and must answer `y` or `yes` on the terminal. Any other
  answer aborts without changes. So does input that is piped or redirected rather than typed.
- **Does only what you were shown.** After you answer, the dry run is repeated. If the list of
  changes is different now (say, a different card with other files was mounted under the same name),
  it stops. Deletions are capped at the number of items the dry run found (files, folders and
  clutter), and a `sync` whose dry run found nothing to delete runs without deleting. A `copy` that
  was not allowed to replace anything runs with rsync's `--ignore-existing`.
- **Extra care with big losses.** If `copy` or `sync` would delete or replace more than half the files
  on `DST` (and more than the list can show), you must type the number of files instead of `y`. That
  usually means the wrong folder was given, e.g. `CARD/DCIM` against the root of a backup drive, or a
  second card with the same file names synced onto the first card's folder.
- **Warns when it can't see clearly.** If the dry run reports errors (an unreadable folder in `SRC`, say), the
  lists are marked as possibly incomplete, the same limits apply, and the run ends with exit status 1
  so you check it.
- **Won't mirror an empty card.** `sync` refuses if `SRC` has no files, so syncing from a freshly
  formatted card cannot wipe your backup.
- **Refuses overlapping folders.** `SRC` and `DST` must be different folders and `DST` may not be
  inside `SRC`; for `sync`, `SRC` may not be inside `DST` either (the mirror would delete `SRC` itself).
  Symlinks and differences in upper/lower case are seen through.
- **Complete or not at all, per file.** rsync checks each file's checksum in transit and only gives it
  its real name once it is fully written, so an interrupted run never leaves a half-copied photo under
  its real name. Re-run to finish. After a power cut or an unplugged drive, run `verify`. A hard
  interruption can also leave a hidden temporary file (`.NAME.xxxxxx`) behind; `sync` will list it for
  deletion. For photos whose names start with `_` (e.g. `_MG_1234.CR3`) that file starts with `._`,
  looks like macOS clutter and is left alone; `find DST -name '._*' -size +100k` finds them.
- **Catches silent corruption.** `verify` compares content checksums, so it finds files whose bytes
  differ even when size and date are identical.
- **Ignores system clutter.** `.DS_Store`, `._*` files, `.Spotlight-V100`, `.fseventsd`, `.Trashes`,
  `System Volume Information` and similar are never copied or compared, and are kept on `DST`.
  The exception: when `sync` removes a folder, the clutter inside it goes too (with Homebrew rsync or
  the openrsync in current macOS; with the rsync 2.6.9 of older macOS such a folder stays behind).
- **Tolerates FAT/exFAT timestamps.** Dates within 2 seconds count as equal, so memory-card files are
  not needlessly re-copied.
- **Stops when it can't see at all.** If a folder on `DST` can't be read, the dry run can't see what
  is in it, so `copy` and `sync` stop and name it. A `DST` on a drive that isn't connected is refused,
  instead of being created on the internal disk.
- **Takes any folder name.** Names with spaces, accents, `:` (which rsync would otherwise read as a
  remote host) or a leading `-` work. For a leading `-`, put `--` before the paths and any option
  before `--`: `photo.sh copy -c -- -card DST`.

## Tests

```bash
/bin/bash photo_tests.sh
```

Runs the helper unit tests and end-to-end `copy` / `sync` / `verify` scenarios on temporary folders,
once for each `rsync` found (Homebrew and/or the macOS built-in), under the stock bash 3.2.
GitHub Actions runs the same suite on macOS for every push.

Both scripts are kept clean under [ShellCheck](https://www.shellcheck.net) (`brew install shellcheck`),
which CI also runs:

```bash
shellcheck -x photo.sh photo_tests.sh
```

The tests answer the script's questions through the `PHOTO_SH_TEST_ANSWER` environment variable,
which only counts when stdin is not a terminal. Don't set it outside the tests. The tests that type
into a real terminal use `expect` (part of macOS) and run only where a pseudo-terminal is available;
CI requires them.

## License

MIT. See [LICENSE](LICENSE).
