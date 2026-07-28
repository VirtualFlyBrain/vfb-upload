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
set -u

UPLOAD="https://upload.virtualflybrain.org/upload"
FILES="https://upload.virtualflybrain.org/files"
CHUNK_MIB=5120                 # 5 GiB parts
TRIES=4                        # attempts per part

die() { echo "ERROR: $*" >&2; exit 1; }
size_of() { wc -c < "$1" | tr -d ' '; }

# ---- what are we uploading? ------------------------------------------------
SRC="${1:-}"
[ -n "$SRC" ] || die "usage: $0 <file-or-folder>"
SRC="${SRC%/}"
[ -e "$SRC" ] || die "no such file or folder: $SRC"

WORK="$HOME/.vfb-upload"
MADE_TAR=""
if [ -d "$SRC" ]; then
  mkdir -p "$WORK/archives" || die "cannot write to $WORK"
  TAR="$WORK/archives/$(basename "$SRC").tar"
  if [ -f "$TAR" ]; then
    echo "Using the tar made earlier: $TAR"
  else
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
SIZE=$(size_of "$SRC")
CHUNK=$(( CHUNK_MIB * 1024 * 1024 ))
NPARTS=$(( (SIZE + CHUNK - 1) / CHUNK ))
[ "$NPARTS" -gt 0 ] || die "$SRC is empty"

STATE="$HOME/.vfb-upload/$NAME"
mkdir -p "$STATE" || die "cannot write to $STATE"
DONEFILE="$STATE/uploaded"; touch "$DONEFILE"

# An id so your parts can't clash with someone else's upload of the same
# filename. Made once, then reused every time you re-run.
if [ -s "$STATE/id" ]; then ID=$(cat "$STATE/id")
else ID="$(date +%Y%m%d-%H%M%S)-$$"; echo "$ID" > "$STATE/id"; fi

# Size of part N on the server, but only from a real 2xx — a 404 reply has a
# Content-Length of its own that must not be read as a file size.
remote_size() {
  local h c
  h=$(curl -sS -I --connect-timeout 30 -H "Authorization: Bearer $TOKEN" "$FILES/$1" 2>/dev/null)
  c=$(printf '%s\n' "$h" | awk 'NR==1{print $2}')
  case "$c" in 2*) printf '%s\n' "$h" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1 ;; esac
}

PART=""
trap 'rm -f "$PART"; echo; echo "Stopped — run the same command again to carry on."; exit 130' INT TERM

echo "Uploading $NAME — $SIZE bytes in $NPARTS part(s) of ${CHUNK_MIB} MiB"
echo

BADPARTS=""
OK=0
for (( i=0; i<NPARTS; i++ )); do
  p=$(printf "%s.%s.part-%04d" "$NAME" "$ID" "$i")
  left=$(( SIZE - i * CHUNK ))
  [ "$left" -gt "$CHUNK" ] && want=$CHUNK || want=$left
  n="[$((i+1))/$NPARTS]"

  if grep -qx "$p" "$DONEFILE"; then echo "$n done already"; OK=$((OK+1)); continue; fi

  # Might already be up there from an earlier run that died mid-way.
  case "$(remote_size "$p")" in
    "$want") echo "$p" >> "$DONEFILE"; echo "$n done already"; OK=$((OK+1)); continue ;;
    "")      ;;
    *)       BADPARTS="$BADPARTS $p"; echo "$n WRONG SIZE on the server — see below"; continue ;;
  esac

  PART="$STATE/$p"
  dd if="$SRC" of="$PART" bs=1048576 skip=$(( i * CHUNK_MIB )) count=$CHUNK_MIB 2>/dev/null
  got=$(size_of "$PART")
  [ "$got" = "$want" ] || { rm -f "$PART"; die "couldn't read part $((i+1)) of $SRC (got $got bytes, wanted $want) — is the file/drive still there? Is the disk full?"; }

  sent=no
  for (( t=1; t<=TRIES; t++ )); do
    echo "$n uploading$([ $t -gt 1 ] && echo " (try $t of $TRIES)") ..."
    # No --fail/--fail-with-body: not present in older curl. Judge by status.
    code=$(curl -sS -# --connect-timeout 30 --speed-limit 10000 --speed-time 600 \
             -H "Authorization: Bearer $TOKEN" -F "file=@$PART" "$UPLOAD" \
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
    "$want") echo "$p" >> "$DONEFILE"; OK=$((OK+1)); echo "$n sent and size-checked" ;;
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
  echo "    parts: $NPARTS, named $NAME.$ID.part-0000 onwards"
  echo
  echo "You can now delete $STATE"
  [ -n "$MADE_TAR" ] && echo "...and the tar we made: $MADE_TAR"
else
  echo "$OK of $NPARTS parts done. Run the same command again to finish."
  exit 1
fi
