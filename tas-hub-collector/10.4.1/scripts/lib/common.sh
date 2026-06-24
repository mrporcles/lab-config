# Echo "$@" to stderr, then execute it.
-() { echo - "$@" 1>&2; "$@"; }

# Echo "$@" to stderr, then execute it and exit on failure.
+() {
  - "$@" && return
  local status=$?
  echo "exit code: $status" 1>&2
  exit $status
}

INPUT_CONF="$1"
PERSISTENCE_URL="$(+ jq -er .persistence.url "$INPUT_CONF")"

argument() { jq -er ".arguments${1:+".$1"}" "$INPUT_CONF"; }

load() {
  curl -sf "$PERSISTENCE_URL" | jq -er ".$1"
}

save() {
  local data="$(load)"
  data="${data:-"{}"}"
  data="$(echo "$data" | jq --argjson override "$1" '. * $override')"
  curl -sf -X POST "$PERSISTENCE_URL" -d "$data"
}

retry() {
  local tries=3
  local status

  while (( tries > 0 ))
  do
    - "$@" && return
    status=$?
    echo "command failed, retrying in 5 mins" 1>&2
    sleep 300
    (( tries-- ))
  done
  echo "error exit: $status" 1>&2
  exit $status
}
