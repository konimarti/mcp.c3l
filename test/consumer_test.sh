#!/bin/sh
# Build a tiny project that depends on this repository as a .c3l library (manifest.json) and talk to it.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$root/test/consumer/." "$tmp/"
mkdir "$tmp/deps"
ln -s "$root" "$tmp/deps/mcp.c3l"
cd "$tmp"
c3c build consumer >/dev/null
out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":2}}}' | out/consumer)
echo "$out" | grep -q '"name":"add"' && echo "$out" | grep -q '"text":"3"' && echo "consumer (c3l dependency): PASS"
