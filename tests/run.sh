#!/bin/bash
#
# Everything, cheapest first.
#
#   tests/run.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

status=0

echo "### syntax"
bash -n "$ROOT/scaffold.sh" && echo "  ok   scaffold.sh" || status=1
python3 -m py_compile "$ROOT/scaffold.py" && echo "  ok   scaffold.py" || status=1
echo

for test in test_flavour.sh test_render.sh test_containers.sh; do
  echo "### $test"
  "$HERE/$test" || status=1
  echo
done

if (( status )); then
  echo "### FAILED"
else
  echo "### all good"
fi

exit $status
