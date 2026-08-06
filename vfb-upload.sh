#!/usr/bin/env bash
#
# vfb-upload.sh — send a large file or folder to Virtual Fly Brain.
#
#   ./vfb-upload.sh mydata.tar        # uploads it in 5 GiB parts
#   ./vfb-upload.sh my-folder/        # tars it first, then uploads
#
# Stop it any time (Ctrl-C) and run the same command again — it carries on.
# Nothing to install: needs only bash, curl and tar.
#
# Things you can set, if you need to:
#   VFB_TOKEN=...            the token VFB emailed you (else you're asked for it)
#   VFB_WORK=/big/disk/vfb   where the tar and the part being sent are written.
#                            Default ~/.vfb-upload — change it if your home
#                            directory is small or has a quota.
#   VFB_CHUNK_MIB=1024       part size in MiB. Default 5120 (5 GiB). Smaller
#                            parts lose less work on a flaky connection.
#   VFB_SHA256=1             also print a checksum at the end, so VFB can check
#                            the reassembled file (reads the whole file again).
#
set -u

UPLOAD="https://upload.virtualflybrain.org/upload"
FILES="https://upload.virtualflybrain.org/files"
CHUNK_MIB="${VFB_CHUNK_MIB:-5120}"   # 5 GiB parts
TRIES=4                              # attempts per part
MAXPARTS=10000                       # part-NNNN, and our reassembly glob, end here
MIB=1048576

die() { echo "ERROR: $*" >&2; exit 1; }
size_of() { wc -c < "$1" | tr -d ' '; }
avail_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# Only [A-Za-z0-9._-] survives. Every part name then goes safely into a URL, a
# multipart header and a shell glob — a space or a '#' in a filename used to
# make the size check fail for ever, so the upload could never finish.
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# GNU stat and BSD stat spell this differently, and BSD's -f means something
# else entirely on GNU, so try GNU first and check we got a number.
mtime_of() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# Where something really is, following links, so two ways of naming the same
# data share one set of saved state.
abs_path() {
  if [ -d "$1" ]; then ( cd "$1" && pwd -P )
  else printf '%s/%s\n' "$( cd "$(dirname "$1")" && pwd -P )" "$(basename "$1")"
  fi
}

# Human-readable version of a count of seconds, e.g. 90 -> "1m30s".
fmt_eta() {
  local s=$1
  if   [ "$s" -lt 60 ];   then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else                         printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# Copy one part out of $SRC. dd counts blocks, not bytes, so a single short
# read — normal on NFS, SMB and sshfs, where lab data usually lives — makes it
# stop early. Keep asking until we have the length we wanted.
read_part() {
  local off_mib=$1 want=$2 out=$3 got prev rem n
  : > "$out" || return 1
  got=0
  while [ "$got" -lt "$want" ]; do
    prev=$got
    rem=$(( want - got ))
    if [ $(( got % MIB )) -eq 0 ] && [ "$rem" -ge "$MIB" ]; then
      dd if="$SRC" bs="$MIB" skip=$(( off_mib + got / MIB )) \
         count=$(( rem / MIB )) 2>/dev/null >> "$out"
    else
      # Byte-at-a-time only to get back onto a MiB boundary (under 1 MiB).
      n=$(( MIB - got % MIB )); [ "$n" -gt "$rem" ] && n=$rem
      dd if="$SRC" bs=1 skip=$(( off_mib * MIB + got )) \
         count="$n" 2>/dev/null >> "$out"
    fi
    got=$(size_of "$out")
    [ "$got" -gt "$prev" ] || return 1     # no progress at all: a real error
  done
  [ "$got" -eq "$want" ]
}

# ---- what are we uploading? ------------------------------------------------
[ $# -eq 1 ] || die "usage: $0 <file-or-folder>
One file or folder at a time. To send several files, put them in a folder and
upload that — the folder is tarred up for you."
ARG="$1"
SRC="${ARG%/}"
[ -n "$SRC" ] || die "usage: $0 <file-or-folder>"
[ -e "$SRC" ] || die "no such file or folder: $SRC"

WORK="${VFB_WORK:-$HOME/.vfb-upload}"
case "$WORK" in
  *'"'*|*'\'*) die "VFB_WORK cannot contain a quote or a backslash: $WORK" ;;
esac
mkdir -p "$WORK" || die "cannot create $WORK — set VFB_WORK to somewhere writable"

case "$CHUNK_MIB" in ''|*[!0-9]*) die "VFB_CHUNK_MIB must be a whole number of MiB" ;; esac
[ "$CHUNK_MIB" -ge 1 ] || die "VFB_CHUNK_MIB must be at least 1"

# A link to a folder: tar would store just the link and none of the data.
if [ -L "$SRC" ] && [ -d "$SRC" ]; then
  REAL=$(abs_path "$SRC")
  [ -n "$REAL" ] || die "cannot follow the link $SRC"
  echo "$SRC is a link to $REAL — uploading what it points at."
  SRC="$REAL"
fi

MADE_TAR=""
if [ -d "$SRC" ]; then
  mkdir -p "$WORK/archives" || die "cannot write to $WORK/archives"
  TAR="$WORK/archives/$(basename "$SRC").tar"
  if [ -f "$TAR" ]; then
    echo "Checking $SRC hasn't changed since the tar was made ..."
    if [ -n "$(find "$SRC" -newer "$TAR" -print 2>/dev/null | head -1)" ]; then
      echo "!! $SRC has changed — making the tar again so you send what's there now."
      rm -f "$TAR"
    fi
  fi
  if [ -f "$TAR" ]; then
    echo "Using the tar made earlier: $TAR"
  else
    echo "Checking there is room in $WORK ..."
    need=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}')
    have=$(avail_kb "$WORK")
    case "${need:-}${have:-}" in
      ''|*[!0-9]*) ;;                       # couldn't measure — carry on and hope
      *) if [ "$have" -lt "$need" ]; then
           die "$WORK has about $(( have / 1048576 )) GiB free, and a tar of $SRC
needs about $(( need / 1048576 )) GiB. Put the working files on a bigger disk:

    VFB_WORK=/path/with/room $0 $ARG"
         fi ;;
    esac
    echo "Making a tar of $SRC (this can take a while) ..."
    tar -cf "$TAR.part" -C "$(dirname "$SRC")" "$(basename "$SRC")" \
      || { rm -f "$TAR.part"; die "tar failed — is there room on the disk for a copy of $SRC?"; }
    mv "$TAR.part" "$TAR"
  fi
  SRC="$TAR"; MADE_TAR="$TAR"
fi
[ -f "$SRC" ] || die "not a regular file: $SRC"
[ -r "$SRC" ] || die "cannot read: $SRC"

# ---- token -----------------------------------------------------------------
TOKEN="${VFB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  printf 'VFB upload token: ' >&2; read -r -s TOKEN; echo >&2
fi
[ -n "$TOKEN" ] || die "no token given (VFB emails you one)"

# ---- work out the parts ----------------------------------------------------
NAME=$(basename "$SRC")
SAFE=$(safe_name "$NAME")
SIZE=$(size_of "$SRC")
CHUNK=$(( CHUNK_MIB * MIB ))
NPARTS=$(( (SIZE + CHUNK - 1) / CHUNK ))
[ "$NPARTS" -gt 0 ] || die "$SRC is empty"
[ "$NPARTS" -le "$MAXPARTS" ] || die "$SRC would be $NPARTS parts, and we can only
put them back together up to $MAXPARTS. Use bigger parts, e.g.:

    VFB_CHUNK_MIB=$(( CHUNK_MIB * 4 )) $0 $ARG"

# State lives under a name made from where the file is, not just what it's
# called: two different files both called data.tar must not share a done-list.
ABS=$(abs_path "$SRC"); [ -n "$ABS" ] || die "cannot work out where $SRC is"
STATE="$WORK/$SAFE-$(printf '%s' "$ABS" | cksum | awk '{print $1}')"
if [ ! -d "$STATE" ] && [ -d "$WORK/$NAME" ] && [ "$NAME" != archives ]; then
  mv "$WORK/$NAME" "$STATE" 2>/dev/null   # state saved by an older version
fi
mkdir -p "$STATE" || die "cannot write to $STATE"
DONEFILE="$STATE/uploaded"; touch "$DONEFILE" || die "cannot write to $STATE"

# Parts already sent only belong to this file if it's still the same file and
# we're still cutting it the same way.
META="$STATE/meta"
STAMP="size=$SIZE chunk=$CHUNK_MIB mtime=$(mtime_of "$SRC")"
if [ -s "$META" ] && [ "$(cat "$META")" != "$STAMP" ]; then
  echo
  echo "!! $NAME is not the file this upload started with — its size, date or"
  echo "!! part size has changed, so the parts already on the server are not"
  echo "!! parts of it. Starting again under a new id."
  echo
  [ -s "$STATE/id" ] && cat "$STATE/id" >> "$STATE/superseded"
  rm -f "$STATE/id"; : > "$DONEFILE"
fi
printf '%s\n' "$STAMP" > "$META"

# An id so your parts can't clash with someone else's upload of the same
# filename. Made once, then reused every time you re-run.
if [ -s "$STATE/id" ]; then ID=$(cat "$STATE/id")
else ID="$(date +%Y%m%d-%H%M%S)-$$"; echo "$ID" > "$STATE/id"; fi

# The token is fed to curl down a pipe: not on the command line, where anyone
# sharing the machine could read it out of `ps`, and not in a file either.
TOKEN_ESC=$(printf '%s' "$TOKEN" | sed 's/[\\"]/\\&/g')   # curl config quoting
token_cfg() { printf 'header = "Authorization: Bearer %s"\n' "$TOKEN_ESC"; }

# Tidy up after a run that was cut short. bash can swallow the Ctrl-C when it
# arrives while curl has the wheel, so the trap below is not to be relied on.
rm -f "$STATE"/*.part-[0-9][0-9][0-9][0-9] "$STATE/curlrc" 2>/dev/null

PART=""
cleanup() { [ -n "$PART" ] && rm -f "$PART"; return 0; }
trap 'cleanup' EXIT
trap 'cleanup; echo; echo "Stopped — run the same command again to carry on."; exit 130' INT TERM

have=$(avail_kb "$STATE")
case "${have:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$have" -ge $(( CHUNK_MIB * 1024 ))  ] || die "$STATE has about $(( have / 1024 )) MiB
free, and one part needs $CHUNK_MIB MiB. Free some space, set VFB_WORK to a
bigger disk, or use smaller parts with VFB_CHUNK_MIB." ;;
esac

# Size of part N on the server, but only from a real 2xx — a 404 reply has a
# Content-Length of its own that must not be read as a file size.
remote_size() {
  local h c
  h=$(token_cfg | curl -sS -I --connect-timeout 30 -K - "$FILES/$1" 2>/dev/null)
  c=$(printf '%s\n' "$h" | awk 'NR==1{print $2}')
  case "$c" in 2*) printf '%s\n' "$h" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1 ;; esac
}

echo "Uploading $NAME — $SIZE bytes in $NPARTS part(s) of ${CHUNK_MIB} MiB"
[ "$SAFE" = "$NAME" ] || echo "(sent under the plainer name $SAFE)"
echo

BADPARTS=""
OK=0
SENT_BYTES=0
RATE_BYTES=0
RATE_SECS=0
for (( i=0; i<NPARTS; i++ )); do
  p=$(printf "%s.%s.part-%04d" "$SAFE" "$ID" "$i")
  left=$(( SIZE - i * CHUNK ))
  [ "$left" -gt "$CHUNK" ] && want=$CHUNK || want=$left
  n="[$((i+1))/$NPARTS]"

  if grep -qxF "$p" "$DONEFILE"; then echo "$n done already"; OK=$((OK+1)); SENT_BYTES=$((SENT_BYTES+want)); continue; fi

  # Might already be up there from an earlier run that died mid-way.
  case "$(remote_size "$p")" in
    "$want") echo "$p" >> "$DONEFILE"; echo "$n done already"; OK=$((OK+1)); SENT_BYTES=$((SENT_BYTES+want)); continue ;;
    "")      ;;
    *)       BADPARTS="$BADPARTS $p"; echo "$n WRONG SIZE on the server — see below"; continue ;;
  esac

  t0=$SECONDS
  PART="$STATE/$p"
  read_part $(( i * CHUNK_MIB )) "$want" "$PART" || {
    got=$(size_of "$PART"); rm -f "$PART"
    die "couldn't read part $((i+1)) of $SRC (got ${got:-0} bytes, wanted $want).
Is the file still there and readable? If it's on a network drive, copy it to a
local disk first, or try smaller parts with VFB_CHUNK_MIB."
  }

  sent=no
  for (( t=1; t<=TRIES; t++ )); do
    echo "$n uploading$([ $t -gt 1 ] && echo " (try $t of $TRIES)") ..."
    # No --fail/--fail-with-body: not present in older curl. Judge by status.
    # The local path is quoted and the remote name given outright, so a comma
    # or semicolon in it can't be read as curl's own syntax.
    # No -s here on purpose: it silences the progress meter, so you'd stare at
    # nothing for an hour per part. The meter goes to stderr; the status we
    # read comes back on stdout, so the two don't collide.
    code=$(token_cfg | curl -S --connect-timeout 30 --speed-limit 10000 --speed-time 600 \
             -K - -F "file=@\"$PART\";filename=\"$p\"" "$UPLOAD" \
             -o "$STATE/last-reply" -w '%{http_code}')
    case "$code" in
      2*|409)   sent=yes; break ;;
      401|403)  rm -f "$PART"; die "the server rejected your token (HTTP $code) — check it with VFB" ;;
    esac
    echo "     failed (HTTP ${code:-none})"
    [ $t -lt $TRIES ] && sleep $(( 20 * t ))
  done

  if [ "$sent" != yes ]; then
    rm -f "$PART"
    [ -s "$STATE/last-reply" ] && { echo "Server said:"; sed 's/^/     /' "$STATE/last-reply"; }
    die "the server isn't accepting $p. Everything sent so far is saved — try again later with the same command."
  fi

  # A 201 doesn't mean it arrived intact: this server has stored empty and
  # truncated files and still reported success. Check the size it really has.
  case "$(remote_size "$p")" in
    "$want")
      echo "$p" >> "$DONEFILE"; OK=$((OK+1)); SENT_BYTES=$((SENT_BYTES+want))
      RATE_BYTES=$((RATE_BYTES+want)); RATE_SECS=$((RATE_SECS + SECONDS - t0))
      msg="$n sent and size-checked"
      remaining=$(( SIZE - SENT_BYTES ))
      if [ "$RATE_SECS" -gt 0 ] && [ "$remaining" -gt 0 ]; then
        rate=$(( RATE_BYTES / RATE_SECS ))   # bytes/sec first, so huge files can't overflow
        [ "$rate" -gt 0 ] && msg="$msg — about $(fmt_eta $(( remaining / rate ))) left"
      fi
      echo "$msg"
      ;;
    "")      echo "$n sent, but couldn't check the size — re-run later to confirm" ;;
    *)       BADPARTS="$BADPARTS $p"; echo "$n sent but stored at the WRONG SIZE — see below" ;;
  esac
  rm -f "$PART"; PART=""
done

echo
if [ -n "$BADPARTS" ]; then
  echo "These parts are on the server at the wrong size. It won't let us replace"
  echo "them, so please ask VFB to delete them, then re-run this script:"
  for b in $BADPARTS; do echo "    $b"; done
  echo
fi

if [ "$OK" -ge "$NPARTS" ]; then
  echo "All $NPARTS part(s) uploaded and size-checked. Please tell VFB:"
  echo "    file:  $NAME"
  echo "    size:  $SIZE bytes"
  echo "    parts: $NPARTS, named $SAFE.$ID.part-0000 onwards"
  if [ "${VFB_SHA256:-}" = 1 ]; then
    echo
    echo "Working out the checksum (reads the whole file again) ..."
    sum=$( { shasum -a 256 "$SRC" 2>/dev/null || sha256sum "$SRC" 2>/dev/null; } | awk 'NR==1{print $1}' )
    [ -n "${sum:-}" ] && echo "    sha256: $sum" || echo "    (no shasum or sha256sum on this machine)"
  fi
  if [ -s "$STATE/superseded" ]; then
    echo
    echo "Also tell VFB these ids are abandoned parts of an earlier attempt and"
    echo "can be deleted:"
    sed 's/^/    /' "$STATE/superseded"
  fi
  echo
  echo "You can now delete $STATE"
  [ -n "$MADE_TAR" ] && echo "...and the tar we made: $MADE_TAR"
  exit 0
else
  echo "$OK of $NPARTS parts done. Run the same command again to finish."
  exit 1
fi
