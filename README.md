# photosync

`photo.sh` is a small macOS script for getting photos off memory cards safely in the field.
It wraps `rsync` with checks that stop you from losing files: it previews what would change,
asks before replacing or deleting anything, and can checksum-verify a copy before you wipe the card.

No state, no config, no database. Each command is one self-contained operation.

## Commands

| Command | What it does |
|---|---|
| `photo.sh copy SRC DST` | Copies everything from `SRC` into `DST`. Never deletes on `DST`. Asks before replacing a file that already exists there with different content. |
| `photo.sh copy SRC DST -c` | Same, then compares checksums of every file on `SRC` and `DST`. |
| `photo.sh sync SRC DST` | Makes `DST` an exact mirror of `SRC`. Lists every file it would delete or replace on `DST` and asks first. |
| `photo.sh verify SRC DST` | Checksum-compares every file on `SRC` against `DST`. Changes nothing. |

`SRC` and `DST` are folders. The *contents* of `SRC` go into `DST` (no extra `SRC` folder is created).
`DST` is created if it does not exist.

## Requirements

- macOS with the stock `bash` (3.2) — nothing else to install.
- `rsync`: the one built into macOS works. [Homebrew](https://brew.sh) `rsync` 3.x is optional and adds
  a single overall progress bar and faster checksums (`brew install rsync`).

## Install

```bash
git clone git@github.com:anullog/photosync.git
cd photosync
chmod +x photo.sh
```

Optional, to run it as `photo.sh` from anywhere:

```bash
sudo mkdir -p /usr/local/bin && sudo ln -s "$PWD/photo.sh" /usr/local/bin/photo.sh
```

## Offloading a card safely

1. Copy and verify:
   ```bash
   photo.sh copy /Volumes/CARD/DCIM ~/Pictures/2026-10-09-shoot -c
   ```
2. Eject the destination drive and plug it back in. Right after a copy, macOS serves most of the
   files from memory, so step 1's check does not prove the data reached the disk.
3. Verify again, now reading from the disk:
   ```bash
   photo.sh verify /Volumes/CARD/DCIM ~/Pictures/2026-10-09-shoot
   ```
4. Only if step 3 prints `checksums match`, format the card in the camera.

If verification fails, the script lists each problem file as `missing` or `differs` and exits with
`VERIFY FAILED — do not wipe the source.`

## Other examples

Back up a photo library to an external drive, keeping it an exact copy:

```bash
photo.sh sync ~/Pictures/Library /Volumes/Backup/Library
```

Add a second card's photos to the same folder (re-running is cheap: unchanged files are skipped):

```bash
photo.sh copy /Volumes/CARD2/DCIM ~/Pictures/2026-10-09-shoot
```

## How it keeps your files safe

- **Complete or not at all.** rsync checks each file's checksum in transit and only gives it its real
  name once it is fully written. An interrupted run never leaves a half-copied photo. Re-run to finish.
- **Asks before destroying anything.** Every `copy` and `sync` starts with a dry run. If any file on
  `DST` would be replaced or deleted, you see the list (first 20, plus a count) and must answer `y`.
  Any other answer, or no terminal to answer from, aborts without changes.
- **Won't mirror an empty card.** `sync` refuses if `SRC` has no files, so syncing from a freshly
  formatted card cannot wipe your backup.
- **Catches silent corruption.** `verify` compares content checksums, so it finds files whose bytes
  differ even when size and date are identical.
- **Ignores system clutter.** `.DS_Store`, `._*` files, `.Spotlight-V100`, `.fseventsd`, `.Trashes`,
  `System Volume Information` and similar are never copied, deleted or compared.
- **Tolerates FAT/exFAT timestamps.** Dates within 2 seconds count as equal, so memory-card files are
  not needlessly re-copied.

## Tests

```bash
bash photo_tests.sh
```

Runs the helper unit tests and end-to-end `copy` / `sync` / `verify` scenarios on temporary folders,
once for each `rsync` found (Homebrew and/or the macOS built-in).
