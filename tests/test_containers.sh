#!/bin/bash
#
# The only test that proves the scaffolding produces something that runs.
#
#   tests/test_containers.sh
#
# Renders each template, builds the image the nullplatform CI would build (a plain
# `docker build .` at the root, which is all the workflow inherited from the "Any
# technology" template does) and asks the container what it is.
#
# Needs a working docker. Skipped, not failed, when there is none: the rendering
# tests still say something useful on a host without it.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

source "$ROOT/scaffold.sh"
set +e

if ! docker info >/dev/null 2>&1; then
  echo "SKIPPED: docker is not available"
  exit 0
fi

WORK=$(mktemp -d)
CONTAINERS=()

cleanup() {
  local container
  for container in "${CONTAINERS[@]:-}"; do
    [[ -n "$container" ]] && docker rm --force "$container" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

export REPOSITORY_NAME APPLICATION_SLUG=payments NAMESPACE_SLUG=billing
export NRN="organization=1:account=2"

failures=0
checked=0

check() {
  local description="$1" expected="$2" actual="$3"

  checked=$((checked + 1))

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %s\n' "$description"
  else
    failures=$((failures + 1))
    printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' \
      "$description" "$expected" "$actual"
  fi
}

# name -> the greeting that container has to answer with
run_flavour() {
  local name="$1" greeting="$2"
  local routed flavour template_dir base_name image container port body

  routed=$(flavour_for "$name")
  IFS=$'\t' read -r flavour template_dir base_name <<<"$routed"

  REPOSITORY_NAME="$name"
  APP_NAME=$(printf '%s' "$base_name" | tr '_' '-' \
    | awk -F- '{for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)}')
  PACKAGE_NAME=$(printf '%s' "$base_name" | tr '_' '-' | tr '[:upper:]' '[:lower:]')

  echo "==> $name ($flavour)"

  mkdir -p "$WORK/$name"
  render_template "$TEMPLATES/$template_dir" "$WORK/$name" >/dev/null

  image="scaffold-demo-test/$name"

  if ! docker build --quiet --tag "$image" "$WORK/$name" >/dev/null 2>"$WORK/$name.build.log"; then
    failures=$((failures + 1))
    checked=$((checked + 1))
    printf '  FAIL docker build\n'
    sed 's/^/         /' "$WORK/$name.build.log" | tail -25
    return
  fi
  checked=$((checked + 1))
  printf '  ok   docker build\n'

  # Port 0 lets docker choose, so a busy 8080 on the host is not this test's
  # problem. 127.0.0.1 keeps it off the network.
  container=$(docker run --detach --publish 127.0.0.1:0:8080 "$image")
  CONTAINERS+=("$container")

  port=$(docker port "$container" 8080/tcp | head -1 | sed 's/.*://')

  for _ in $(seq 1 40); do
    curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
    sleep 1
  done

  body=$(curl --silent --max-time 5 "http://127.0.0.1:$port/")
  check "answers the greeting on /" "$greeting" "$body"

  body=$(curl --silent --max-time 5 "http://127.0.0.1:$port/health")
  check "answers on /health" '{"status":"ok"}' "$body"

  docker rm --force "$container" >/dev/null 2>&1
  docker rmi --force "$image" >/dev/null 2>&1
}

run_flavour net-payments-api "hello world. I am an app built in .NET"
run_flavour node-payments-api "hello world. I am an app built in Node"

echo
if (( failures )); then
  echo "FAILED: $failures of $checked checks"
  exit 1
fi

echo "PASSED: $checked checks"
