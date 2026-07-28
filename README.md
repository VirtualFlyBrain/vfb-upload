# Sending large files to Virtual Fly Brain

One script. Point it at a file or a folder and it uploads it to VFB in 5 GiB
parts, checking each part as it goes. Stop it whenever you like and run the same
command again — it picks up where it left off.

Works on macOS and Linux. Nothing to install.

## Use it

Download [`vfb-upload.sh`](vfb-upload.sh), or:

```sh
curl -O https://raw.githubusercontent.com/YOUR-ORG/vfb-upload/main/vfb-upload.sh
chmod +x vfb-upload.sh
```

Then:

```sh
./vfb-upload.sh mydata.tar        # upload a file
./vfb-upload.sh my-folder/        # tar the folder first, then upload
```

It asks for the upload token VFB emailed you. To avoid retyping it:

```sh
export VFB_TOKEN=your-token-here
```

You'll see:

```
Uploading mydata.tar — 257698037760 bytes in 48 part(s) of 5120 MiB

[1/48] uploading ...
######################################################### 100.0%
[1/48] sent and size-checked
[2/48] uploading ...
```

Big uploads take hours — leaving it running overnight is fine. If the
connection drops or the machine sleeps, just run the same command again.

When it finishes it prints a short summary. **Email that to VFB** so we know to
go and collect it.

## Questions

**Can I interrupt it?** Yes. Ctrl-C, or shut the laptop. Re-run the same command
to continue; parts already sent are not sent again.

**How much spare disk do I need?** About 5 GB — one part at a time is written to
`~/.vfb-upload/` and deleted as soon as it's safely uploaded. Uploading a
*folder* also needs room for the tar, so roughly the size of the folder again.

**It says a part is the WRONG SIZE.** The server won't let us overwrite a file,
so a part that arrived damaged has to be deleted at our end first. Send VFB the
part names it listed, and re-run once we've confirmed.

**Want a checksum?** Send us the output of `shasum -a 256 mydata.tar` (macOS) or
`sha256sum mydata.tar` (Linux) and we'll check the reassembled file against it.

**Anything else** — send VFB the last 20 lines the script printed.

---

## For VFB staff

Parts are named `<file>.<id>.part-0000`, `.part-0001`, … in order. Reassemble:

```sh
cat mydata.tar.20260728-153205-66132.part-* > mydata.tar
```

The glob sorts correctly to 10,000 parts (~48 TiB). Check the byte count against
the size the uploader reported before deleting the parts.

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
