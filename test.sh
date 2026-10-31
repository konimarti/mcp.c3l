#!/bin/sh
# Build everything and run all tests. Usage: PATH=/path/to/c3:$PATH ./test.sh
set -e
cd "$(dirname "$0")"
c3c build demo >/dev/null
c3c build c3dev >/dev/null
c3c test 2>&1 | grep -E "Test Result" || true
c3c test >/dev/null
python3 test/protocol_test.py | grep -c PASS | sed 's/^/protocol checks passed: /'
python3 test/protocol_test.py > /dev/null
python3 test/redteam_test.py | grep -c PASS | sed "s/^/redteam regression checks passed: /"
python3 test/redteam_test.py > /dev/null
python3 test/c3dev_test.py > /dev/null && echo "c3dev e2e: PASS"
test/consumer_test.sh
echo "ALL OK"
