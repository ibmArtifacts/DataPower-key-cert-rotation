#!/usr/bin/env bash
#
# rotate_dp_crypto.sh - rotate a Crypto Key + Crypto Certificate on IBM DataPower 10.6.0.x
#                       using the REST management interface (default port 5554).
#
# Usage:
#   ./rotate_dp_crypto.sh              rotate: upload the new key/cert found in the current
#                                      directory to cert:/// with a date/time appended to the
#                                      file name, then point the Crypto Key / Crypto Certificate
#                                      objects at the new files.
#   ./rotate_dp_crypto.sh --rollback   point the objects back at the file names they used
#                                      before the last rotation.
#
# The previous file names are saved next to this script in ".last_rotation".
# Files are never deleted from cert:///, so rollback only changes the objects.
#
# Requires: bash, curl, jq, base64 (openssl optional: checks that the key matches the cert).
# Optional env vars to skip prompts:
#   DP_HOST DP_PORT DP_DOMAIN DP_USER DP_PASS DP_KEY_OBJ DP_CERT_OBJ DP_NEW_KEY DP_NEW_CERT
#   (DP_KEY_OBJ / DP_CERT_OBJ = Crypto Key / Crypto Certificate object names to rotate)
#   (DP_NEW_KEY / DP_NEW_CERT = paths of the new key / cert files; relative paths are
#    relative to where the script is run. When BOTH are set, the "type yes" prompt is skipped.)

set -u
umask 077

for b in curl jq base64; do
  command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' is required." >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$SCRIPT_DIR/.last_rotation"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

die()  { echo "ERROR: $*" >&2; exit 1; }
prompt() {  # prompt VAR "Question" [default]
  local ans
  if [[ -n "${3:-}" ]]; then read -r -p "$2 [$3]: " ans; ans="${ans:-$3}"; else read -r -p "$2: " ans; fi
  printf -v "$1" '%s' "${ans%$'\r'}"
}

MODE=rotate
case "${1:-}" in
  "") ;;
  --rollback|-r) MODE=rollback ;;
  *) echo "Usage: $0 [--rollback]" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- connection
HOST="${DP_HOST:-}"; PORT="${DP_PORT:-5554}"; DOMAIN="${DP_DOMAIN:-}"
if [[ "$MODE" == rollback ]]; then
  [[ -f "$STATE" ]] || die "no rollback information found ($STATE). Run a rotation first."
  # shellcheck disable=SC1090
  source "$STATE"
  echo "Rollback target: $HOST:$PORT domain '$DOMAIN'"
else
  [[ -n "$HOST" ]]   || prompt HOST   "DataPower host/IP"
  [[ -n "${DP_PORT:-}" ]] || prompt PORT "REST management port" "5554"
  [[ -n "$DOMAIN" ]] || prompt DOMAIN "Application domain" "apiconnect"
fi
USER_NAME="${DP_USER:-}"; [[ -n "$USER_NAME" ]] || prompt USER_NAME "Username"
PASS="${DP_PASS:-}"; if [[ -z "$PASS" ]]; then read -r -s -p "Password: " PASS; echo; fi
[[ -n "$HOST" && -n "$DOMAIN" && -n "$USER_NAME" && -n "$PASS" ]] || die "host, domain, username and password are required."

API="https://$HOST:$PORT/mgmt"
CFG="$API/config/$DOMAIN"
FS="$API/filestore/$DOMAIN/cert"

# api METHOD URL [BODYFILE] -> prints HTTP code, response body in $TMP/out.json.
# The gateway's self-signed management certificate is trusted (-k).
# Credentials go to curl on stdin so they are not visible in the process list.
api() {
  local a=(-sS -k -X "$1" -K - -H "Accept: application/json" -o "$TMP/out.json" -w '%{http_code}') u p
  [[ -n "${3:-}" ]] && a+=(-H "Content-Type: application/json" --data-binary "@$3")
  u="${USER_NAME//\\/\\\\}"; u="${u//\"/\\\"}"
  p="${PASS//\\/\\\\}";      p="${p//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$u" "$p" | curl "${a[@]}" "$2"
}
fail() { echo "ERROR: $1 (HTTP ${2:-?})" >&2; jq -r '.error // .' "$TMP/out.json" 2>/dev/null | head -n 5 >&2; }

# get_filename CLASS OBJECT -> prints the object's current Filename
get_filename() {
  local code
  code="$(api GET "$CFG/$1/$2")" || return 1
  [[ "$code" == 200 ]] || { fail "cannot read $1 '$2'" "$code"; return 1; }
  jq -r --arg c "$1" '.[$c].Filename' "$TMP/out.json"
}

# set_filename CLASS OBJECT FILE -> points the object at FILE.
# DataPower does not accept PATCH on config objects (HTTP 405), so the full object is
# read, only Filename is changed, and it is written back with PUT.
set_filename() {
  local code
  code="$(api GET "$CFG/$1/$2")" || return 1
  [[ "$code" == 200 ]] || { fail "cannot read $1 '$2'" "$code"; return 1; }
  jq --arg c "$1" --arg f "$3" 'del(._links) | .[$c] |= (del(.href) | .Filename = $f)' "$TMP/out.json" > "$TMP/body.json" \
    || { echo "ERROR: could not build the update for $1 '$2'" >&2; return 1; }
  code="$(api PUT "$CFG/$1/$2" "$TMP/body.json")" || return 1
  [[ "$code" == 2* ]] || { fail "cannot update $1 '$2'" "$code"; return 1; }
  echo "[+] $1 '$2' -> $3"
}

save_config() {
  local code
  echo '{"SaveConfig":{}}' > "$TMP/body.json"
  code="$(api POST "$API/actionqueue/$DOMAIN" "$TMP/body.json")" || code=0
  if [[ "$code" == 2* ]]; then echo "[+] Configuration saved."
  else echo "[!] Could not save the configuration (HTTP $code); save it manually in the '$DOMAIN' domain." >&2; fi
}

# ------------------------------------------------------------------ rollback
if [[ "$MODE" == rollback ]]; then
  echo "  Crypto Key         '$KEY_OBJ'  -> $OLD_KEY_FILE   (currently $NEW_KEY_FILE)"
  echo "  Crypto Certificate '$CERT_OBJ' -> $OLD_CERT_FILE   (currently $NEW_CERT_FILE)"
  prompt OK "Roll back to the previous files? Type 'yes' to continue" "no"
  [[ "$OK" == yes ]] || { echo "Aborted."; exit 0; }
  set_filename CryptoKey "$KEY_OBJ" "$OLD_KEY_FILE" || exit 1
  if ! set_filename CryptoCertificate "$CERT_OBJ" "$OLD_CERT_FILE"; then
    set_filename CryptoKey "$KEY_OBJ" "$NEW_KEY_FILE" >/dev/null
    die "certificate rollback failed; the key object was put back on the new file."
  fi
  save_config
  echo "[+] Rollback complete."
  exit 0
fi

# -------------------------------------------------------------------- rotate
# List existing objects so the user can pick the right names.
for cls in CryptoKey CryptoCertificate; do
  code="$(api GET "$CFG/$cls")" || die "cannot connect to $HOST:$PORT"
  [[ "$code" == 200 ]] || { fail "cannot list $cls objects" "$code"; exit 1; }
  echo "$cls objects in '$DOMAIN':"
  jq -r --arg c "$cls" '(.[$c] // []) | if type=="array" then . else [.] end | .[] | "  \(.name)  ->  \(.Filename)"' "$TMP/out.json"
done
echo
KEY_OBJ="${DP_KEY_OBJ:-}";   [[ -n "$KEY_OBJ" ]]  || prompt KEY_OBJ  "Crypto Key object name to update"
CERT_OBJ="${DP_CERT_OBJ:-}"; [[ -n "$CERT_OBJ" ]] || prompt CERT_OBJ "Crypto Certificate object name to update"
OLD_KEY_FILE="$(get_filename CryptoKey "$KEY_OBJ")"          || exit 1
OLD_CERT_FILE="$(get_filename CryptoCertificate "$CERT_OBJ")" || exit 1

# Find the new key/cert: use the env var path if set, otherwise look in the current directory.
pick_local() {  # pick_local VAR key|cert ENVVALUE
  local f hits=() ans="${3:-}"
  if [[ -n "$ans" ]]; then
    [[ -f "$ans" && -s "$ans" ]] || die "new $2 file from environment not found or empty: '$ans'"
    echo "[*] Using new $2 file from environment: $ans"
    printf -v "$1" '%s' "$ans"
    return
  fi
  for f in *.pem *.key *.crt *.cer; do
    [[ -f "$f" ]] || continue
    if [[ "$2" == key ]]; then
      grep -q 'PRIVATE KEY' "$f" && hits+=("$f")
    elif grep -q 'BEGIN CERTIFICATE' "$f" && ! grep -q 'PRIVATE KEY' "$f"; then
      hits+=("$f")
    fi
  done
  ((${#hits[@]} == 1)) && ans="${hits[0]}" || ans=""
  ((${#hits[@]} > 1)) && echo "Candidate $2 files here: ${hits[*]}"
  while true; do
    prompt ans "New $2 file (in $PWD)" "$ans"
    [[ -f "$ans" && -s "$ans" ]] && break
    echo "[!] '$ans' not found or empty in $PWD" >&2; ans=""
  done
  printf -v "$1" '%s' "$ans"
}
pick_local NEW_KEY  key  "${DP_NEW_KEY:-}"
pick_local NEW_CERT cert "${DP_NEW_CERT:-}"

if command -v openssl >/dev/null 2>&1; then
  a="$(openssl x509 -in "$NEW_CERT" -noout -pubkey 2>/dev/null)"
  b="$(openssl pkey -in "$NEW_KEY" -pubout 2>/dev/null </dev/null)"
  [[ -z "$a" || -z "$b" || "$a" == "$b" ]] || die "the new key does not match the new certificate."
fi

# Append date/time to the file names: name.pem -> name_20261030121500.pem
TS="$(date +%Y%m%d%H%M%S)"
stamp() { if [[ "$1" == *.* ]]; then echo "${1%.*}_${TS}.${1##*.}"; else echo "${1}_${TS}"; fi; }
NEW_KEY_FILE="$(stamp "$(basename "$NEW_KEY")")"
NEW_CERT_FILE="$(stamp "$(basename "$NEW_CERT")")"
for n in "$NEW_KEY_FILE" "$NEW_CERT_FILE"; do
  [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || die "file name '$n' has characters DataPower should not see; rename the local file."
done

echo
echo "Upload to cert:///   $NEW_KEY_FILE   $NEW_CERT_FILE"
echo "Crypto Key         '$KEY_OBJ':  $OLD_KEY_FILE  ->  cert:///$NEW_KEY_FILE"
echo "Crypto Certificate '$CERT_OBJ': $OLD_CERT_FILE  ->  cert:///$NEW_CERT_FILE"
echo "Local files        key: $NEW_KEY   cert: $NEW_CERT"
if [[ -n "${DP_NEW_KEY:-}" && -n "${DP_NEW_CERT:-}" ]]; then
  echo "[*] DP_NEW_KEY and DP_NEW_CERT are set; continuing without confirmation."
else
  prompt OK "Type 'yes' to continue" "no"
  [[ "$OK" == yes ]] || { echo "Aborted."; exit 0; }
fi

upload() {  # upload LOCALFILE REMOTENAME
  local code
  base64 < "$1" | tr -d '\n' > "$TMP/b64"
  jq -n --arg n "$2" --rawfile c "$TMP/b64" '{file:{name:$n,content:$c}}' > "$TMP/body.json"
  code="$(api POST "$FS" "$TMP/body.json")" || return 1
  [[ "$code" == 2* ]] || { fail "upload of $2 failed" "$code"; return 1; }
  echo "[+] Uploaded $1 -> cert:///$2"
}
upload "$NEW_KEY"  "$NEW_KEY_FILE"  || exit 1
upload "$NEW_CERT" "$NEW_CERT_FILE" || exit 1

# Switch the objects. If the cert object fails, put the key object back.
set_filename CryptoKey "$KEY_OBJ" "cert:///$NEW_KEY_FILE" || exit 1
if ! set_filename CryptoCertificate "$CERT_OBJ" "cert:///$NEW_CERT_FILE"; then
  set_filename CryptoKey "$KEY_OBJ" "$OLD_KEY_FILE" >/dev/null
  die "certificate update failed; the key object was put back on $OLD_KEY_FILE."
fi
save_config

printf 'HOST=%q\nPORT=%q\nDOMAIN=%q\nKEY_OBJ=%q\nCERT_OBJ=%q\nOLD_KEY_FILE=%q\nOLD_CERT_FILE=%q\nNEW_KEY_FILE=%q\nNEW_CERT_FILE=%q\n' \
  "$HOST" "$PORT" "$DOMAIN" "$KEY_OBJ" "$CERT_OBJ" "$OLD_KEY_FILE" "$OLD_CERT_FILE" \
  "cert:///$NEW_KEY_FILE" "cert:///$NEW_CERT_FILE" > "$STATE"
echo "[+] Rotation complete. To roll back: $0 --rollback"
