# Echo "$@" to stderr, then execute it.
-() { echo - "$@" 1>&2; "$@"; }

# Echo "$@" to stderr, then execute it and exit on failure.
+() {
  - "$@" && return
  local status=$?
  echo "exit code: $status" 1>&2
  exit $status
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
