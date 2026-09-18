#!/bin/bash
#
# Parity test for the flavour routing.
#
# The point of this repository is two implementations that do the same thing, so
# the routing is tested ONCE against both of them rather than twice in isolation:
# a table that bash and Python must agree on cannot drift without this failing.
#
#   tests/test_flavour.sh
#
# Nothing here touches GitHub or nullplatform. Sourcing scaffold.sh stops before
# its main body, and scaffold.py is imported rather than run.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

# scaffold.sh sets -e, which would abort this runner on the first failing case.
source "$ROOT/scaffold.sh"
set +e

# Each row: repository name, then the flavour / template directory / base name the
# routing is expected to produce, or `unknown` for a name that routes nowhere.
CASES=(
  "net-payments-api|.NET	dotnet	payments-api"
  "node-payments-api|Node	node	payments-api"
  "net-a|.NET	dotnet	a"
  "node-a|Node	node	a"

  # Case is not the caller's problem: GitHub allows capitals in a repository name.
  "NET-Payments-API|.NET	dotnet	Payments-API"
  "Node-Thing|Node	node	Thing"

  # Underscores are already treated as the same separator as hyphens when the
  # assembly name is derived, so the routing treats them the same way too.
  "net_payments_api|.NET	dotnet	payments-api"
  "node_payments|Node	node	payments"

  # The prefix is `net-`, not `net`. These must NOT route, or every repository
  # starting with those three letters gets a .NET skeleton it never asked for.
  "netflix-clone|unknown"
  "network-proxy|unknown"
  "nodemon-runner|unknown"

  # No prefix at all: the README's documented "leave the repository as it is".
  "payments-api|unknown"
  "api|unknown"

  # A prefix and nothing else leaves no name to build an app out of.
  "net-|unknown"
  "node-|unknown"
  "net_|unknown"
)

ask_bash() {
  local result
  if result=$(flavour_for "$1"); then
    printf '%s' "$result"
  else
    printf 'unknown'
  fi
}

ask_python() {
  python3 - "$ROOT/scaffold.py" "$1" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("scaffold", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

routed = module.flavour_for(sys.argv[2])
print("unknown" if routed is None else "\t".join(routed), end="")
PY
}

failures=0
checked=0

check() {
  local label="$1" name="$2" expected="$3" actual="$4"

  checked=$((checked + 1))

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %-8s %-20s -> %s\n' "$label" "$name" "${actual//	/ }"
  else
    failures=$((failures + 1))
    printf '  FAIL %-8s %-20s -> %s (expected %s)\n' \
      "$label" "$name" "${actual//	/ }" "${expected//	/ }"
  fi
}

echo "==> flavour routing"

for row in "${CASES[@]}"; do
  name="${row%%|*}"
  expected="${row#*|}"

  check bash "$name" "$expected" "$(ask_bash "$name")"
  check python "$name" "$expected" "$(ask_python "$name")"
done

echo
if (( failures )); then
  echo "FAILED: $failures of $checked checks"
  exit 1
fi

echo "PASSED: $checked checks"
