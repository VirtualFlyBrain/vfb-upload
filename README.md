# Sending large files to Virtual Fly Brain

One script. Point it at a file or a folder and it uploads it to VFB in 5 GiB
parts, checking each part as it goes. Stop it whenever you like and run the same
command again — it picks up where it left off.

Works on macOS and Linux. Nothing to install. (On Windows, run it under WSL or
Git Bash.)

## Use it

Download [`vfb-upload.sh`](vfb-upload.sh), or:

```sh
curl -O https://raw.githubusercontent.com/VirtualFlyBrain/vfb-upload/main/vfb-upload.sh
chmod +x vfb-upload.sh
```

or clone the repo:

```sh
git clone https://github.com/VirtualFlyBrain/vfb-upload.git
cd vfb-upload
```

Then:

```sh
./vfb-upload.sh mydata.tar        # upload a file
./vfb-upload.sh my-folder/        # tar the folder first, then upload
```

One file or folder at a time. To send several files, put them in a folder and
upload that.

It asks for the upload token VFB emailed you. To avoid retyping it:

```sh
export VFB_TOKEN=your-token-here
```

You'll see:

```
Uploading mydata.tar — 257698037760 bytes in 48 part(s) of 5120 MiB

[1/48] uploading ...
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 5120M    0     2  100 5120M      0  12.4M  0:06:52  0:06:52 --:--:-- 12.4M
[1/48] sent and size-checked — about 5h22m left
[2/48] uploading ...
```

The `Upload` column is your current speed and `Time Left` counts down the part
being sent; the script's own `about ... left` is for the whole file. Progress
goes to stderr, so redirecting it away (`2>/dev/null`) hides errors too.

Big uploads take hours — leaving it running overnight is fine. If the
connection drops or the machine sleeps, just run the same command again.

When it finishes it prints a short summary. **Email that to VFB** so we know to
go and collect it.

## Settings

Only needed if the defaults don't suit your machine.

| | |
|---|---|
| `VFB_WORK=/big/disk/vfb` | Where the tar and the part being sent are written. Default `~/.vfb-upload`. **Set this if your home directory is small or has a quota** — on a cluster it usually does, and a folder upload needs room for a whole tar. |
| `VFB_CHUNK_MIB=1024` | Part size in MiB, default `5120` (5 GiB). Smaller parts lose less work when a connection keeps dropping, as a failed part is sent again from the start. |
| `VFB_SHA256=1` | Print a checksum at the end so we can verify the reassembled file. Reads the whole file again, so it adds time. |

```sh
VFB_WORK=/scratch/$USER/vfb VFB_CHUNK_MIB=1024 ./vfb-upload.sh my-folder/
```

## Questions

**Can I interrupt it?** Yes. Ctrl-C, or shut the laptop. Re-run the same command
to continue; parts already sent are not sent again.

**How much spare disk do I need?** About 5 GB — one part at a time is written to
`~/.vfb-upload/` (or `VFB_WORK`) and deleted as soon as it's safely uploaded.
Uploading a *folder* also needs room for the tar, so roughly the size of the
folder again. The script checks before it starts and tells you if there isn't
room.

**I changed the folder and re-ran it.** It notices, makes the tar again and
starts a fresh upload, because the parts already sent belong to the old
contents. It prints the id of the abandoned attempt — pass that on so we can
delete it.

**My file has spaces or other punctuation in its name.** Fine. The parts are
sent under a plainer name (`My Lab Data.tar` → `My_Lab_Data.tar`); the script
tells you when it does this, and the file itself is untouched.

**It says a part is the WRONG SIZE.** The server won't let us overwrite a file,
so a part that arrived damaged has to be deleted at our end first. Send VFB the
part names it listed, and re-run once we've confirmed.

**Anything else** — send VFB the last 20 lines the script printed.

---

## For VFB staff

Parts are named `<safe-name>.<id>.part-0000`, `.part-0001`, … in order, where
`<safe-name>` is the filename with anything outside `[A-Za-z0-9._-]` turned into
`_`. Reassemble:

```sh
cat My_Lab_Data.tar.20260728-153205-66132.part-* > My_Lab_Data.tar
```

The glob sorts correctly to 10,000 parts (~48 TiB, at the default part size);
the script refuses to go past that. Check the byte count against the size the
uploader reported before deleting the parts.

Why the script is shaped the way it is — `simple-upload-server` v2 quirks that
cost us a day in July 2026:

- **A `201` does not mean the part is intact.** It has stored empty and
  truncated files and still reported success. So every part's size is confirmed
  with a `HEAD` afterwards, and a length is only trusted from a genuine `2xx`
  (a `404` body carries its own `Content-Length` of 37 bytes).
- **Overwrite and delete are both refused** (`409` / `405`), so a damaged part
  can only be fixed by deleting it server-side.
- **The server's request timeout must be `-1` to disable it** — `0` is the
  default (~15 s), despite what the docs say. With the default, anything taking
  over ~15 s dies with `curl (52) empty reply` or a `500`.
- The `<id>` in each part name exists because the upload namespace is shared and
  overwrites are refused: without it, two users sending `data.tar` would collide
  permanently.
- No `--fail-with-body` / `--fail` in the curl calls: those need curl ≥ 7.76 and
  users may well have older (conda ships 7.68). Outcomes are judged from
  `%{http_code}` instead.

And why some of the rest of it is the way it is:

- **Part names are sanitised** because the size check fetches `/files/<part>`.
  A space made curl reject the URL outright, so the check could never succeed,
  so the part was never recorded as done — the upload retried for ever and never
  finished. A `#` silently truncated the URL to a fragment.
- **Saved state is keyed on the file's resolved path**, plus a stamp of its size,
  mtime and part size. Keyed on the basename alone, two different `data.tar`s
  shared one id and done-list: the second one's parts hit `409`, which we treat
  as "already there", and the `HEAD` then confirmed the *first* file's part size.
  That silently produced a file stitched from both.
- **`dd` is looped until the part is the length we asked for.** It counts blocks,
  not bytes, so one short read — normal on NFS, SMB and sshfs, where lab data
  tends to live — makes it stop early.
- **Stale parts are swept at startup** rather than only in the exit trap: bash
  can swallow a Ctrl-C that arrives while curl has the wheel, so the trap
  doesn't always get to run.
- **A folder given as a symlink is resolved first.** `tar -C parent basename`
  otherwise stores just the symlink, giving a 1.5 KB tar with none of the data
  and no error.
