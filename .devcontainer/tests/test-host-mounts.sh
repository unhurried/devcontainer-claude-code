#!/usr/bin/env bash
# Exercise generate-host-mounts.sh: HOST_MOUNTS parsing, validation, and the generated
# file as compose merges it with docker-compose.yml. Needs the docker compose CLI only
# (`config` does not talk to the daemon).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/../scripts/generate-host-mounts.sh"
COMPOSE="$HERE/../docker-compose.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/mounts.yml"
# Never the real .devcontainer/.env.
export ENV_FILE="$WORK/.env"
unset HOST_MOUNTS

mkdir -p "$WORK/host/My Files/docs" "$WORK/host/notes" "$WORK/host/other/notes" \
    "$WORK/host/.hidden" "$WORK/host/odd\$x\"q"

failures=0
check() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$label"
    else
        printf 'FAIL - %s (want %s, got %s)\n' "$label" "$want" "$got" >&2
        failures=$((failures + 1))
    fi
}

# gen: run the generator, echo its exit status.
gen() { local rc=0; bash "$GEN" "$OUT" >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?; echo "$rc"; }

# mounts JQ: the generated mounts (those under /workspaces/mnt) after the compose merge.
mounts() {
    docker compose -p hostmountstest -f "$COMPOSE" -f "$OUT" config --format json \
        | jq -c "[.services.dev.volumes[] | select(.target | startswith(\"/workspaces/mnt/\"))] | $1"
}

# --- no mounts -------------------------------------------------------------------------
rm -f "$ENV_FILE"
check "no .env: exits 0" 0 "$(gen)"
check "no .env: no mounts" 0 "$(mounts length)"
check "no .env: base volumes kept" true "$(docker compose -p hostmountstest -f "$COMPOSE" -f "$OUT" \
    config --format json | jq '.services.dev.volumes | any(.target == "/workspaces/devcontainer-claude-code")')"

printf 'PROXY_MODE=open\n' >"$ENV_FILE"
check ".env without HOST_MOUNTS: no mounts" "0 0" "$(gen) $(mounts length)"

# --- parsing ---------------------------------------------------------------------------
export HOST_MOUNTS="$WORK/host/My Files/docs/:ro ; $WORK/host/notes;"
check "env: exits 0" 0 "$(gen)"
check "env: targets by basename, in order" \
    '["/workspaces/mnt/docs","/workspaces/mnt/notes"]' "$(mounts 'map(.target)')"
check "env: source keeps spaces, trailing slash dropped" \
    "\"$WORK/host/My Files/docs\"" "$(mounts '.[0].source')"
check "env: :ro is read-only, the rest read-write" '[true,false]' \
    "$(mounts 'map(.read_only // false)')"
check "env: no host path is created" '[false,false]' "$(mounts 'map(.bind.create_host_path)')"

HOST_MOUNTS="$WORK/host/notes"$'\n'"$WORK/host/My Files/docs"
check "env: newline separates entries" '2' "$(gen >/dev/null; mounts length)"

HOST_MOUNTS="$WORK/host/odd\$x\"q"
check "env: \$ and \" survive compose interpolation" 0 "$(gen)"
# config re-escapes $ as $$ on output; an unescaped $x would have been interpolated away.
check "env: \$ and \" in source" "\"$WORK/host/odd\$\$x\\\"q\"" "$(mounts '.[0].source')"

printf 'HOST_MOUNTS=%s\n' "$WORK/host/notes" >"$ENV_FILE"
HOST_MOUNTS=
check "empty env var overrides .env" "0 0" "$(gen) $(mounts length)"
unset HOST_MOUNTS

dotenv_case() {
    local label="$1" content="$2" want="$3"
    printf '%s' "$content" >"$ENV_FILE"
    check ".env $label" "0 $want" "$(gen) $(mounts 'map(.target)')"
}
dotenv_case "unquoted, with comment" \
    "HOST_MOUNTS=$WORK/host/notes # mine"$'\n' '["/workspaces/mnt/notes"]'
dotenv_case "double-quoted, spaces" \
    "HOST_MOUNTS=\"$WORK/host/My Files/docs;$WORK/host/notes:ro\""$'\n' \
    '["/workspaces/mnt/docs","/workspaces/mnt/notes"]'
dotenv_case "single-quoted, CRLF, no final newline" \
    "PROXY_MODE=open"$'\r\n'"HOST_MOUNTS='$WORK/host/notes'" '["/workspaces/mnt/notes"]'
dotenv_case "last assignment wins" \
    "HOST_MOUNTS=$WORK/host/other/notes"$'\n'"HOST_MOUNTS=$WORK/host/notes"$'\n' \
    '["/workspaces/mnt/notes"]'
check ".env: source of the last assignment" "\"$WORK/host/notes\"" "$(mounts '.[0].source')"

# --- validation ------------------------------------------------------------------------
printf 'HOST_MOUNTS=%s\n' "$WORK/host/notes" >"$ENV_FILE"
gen >/dev/null
before="$(cat "$OUT")"

reject() {
    local label="$1" spec="$2" pattern="$3"
    local rc
    rc="$(HOST_MOUNTS="$spec" gen)"
    check "rejects $label: exit status" 1 "$rc"
    check "rejects $label: message" 1 "$(grep -c -- "$pattern" "$WORK/stderr" || true)"
}
reject "a relative path" "host/notes" "not an absolute path"
reject "a missing directory" "$WORK/host/nope" "not an existing directory"
reject "a file" "$ENV_FILE" "not an existing directory"
reject "a duplicate basename" "$WORK/host/notes;$WORK/host/other/notes" "both mount at"
reject "a dot name" "$WORK/host/.hidden" "starts with '.'"
reject "/" "/" "no name for it"
check "a rejected spec leaves the previous file" "$before" "$(cat "$OUT")"
check "no temp files left behind" 1 "$(find "$WORK" -maxdepth 1 -name 'mounts.yml*' | wc -l)"

if [ "$failures" -gt 0 ]; then
    printf '%d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
