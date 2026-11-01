"""Regression tests for the red-team findings. Every input here once crashed, hung or
mis-answered the server. Usage: python3 test/redteam_test.py [demo-binary] [c3dev-binary]"""
import json, os, subprocess, sys, time

DEMO = sys.argv[1] if len(sys.argv) > 1 else "build/demo"
C3DEV = sys.argv[2] if len(sys.argv) > 2 else "build/c3dev"
fails = []

def run(binary, lines, raw=None, timeout=20):
    data = raw if raw is not None else "\n".join(lines) + "\n"
    p = subprocess.run([binary], input=data, capture_output=True, text=True, encoding="utf-8", timeout=timeout)
    out = []
    for l in p.stdout.splitlines():
        if l.strip():
            out.append(json.loads(l))          # every output line must be valid JSON
    return p.returncode, out, p.stderr

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)[:300]))
    if not cond: fails.append(name)

def one(binary, req):
    rc, out, err = run(binary, [json.dumps(req)])
    return rc, (out[0] if out else None)

def call(name, args, id_=1):
    return {"jsonrpc": "2.0", "id": id_, "method": "tools/call", "params": {"name": name, "arguments": args}}

# --- process must survive non-object params (was SIGILL)
for bad in (None, [], "str", 42):
    for m in ("tools/call", "initialize"):
        rc, r = one(DEMO, {"jsonrpc": "2.0", "id": 1, "method": m, "params": bad})
        ok = rc == 0 and r is not None and (("error" in r and r["error"]["code"] == -32602) or m == "initialize" and bad is None)
        check(f"{m} params={bad!r} survives", ok, (rc, r))

# --- notifications never get a reply, for every method
for m in ("ping", "initialize", "tools/list", "tools/call", "nonsense"):
    rc, out, _ = run(DEMO, [json.dumps({"jsonrpc": "2.0", "method": m})])
    check(f"notification {m} -> no reply", rc == 0 and out == [], out)

# --- required params enforced (was: silently 0 / SIGILL for String)
rc, r = one(DEMO, call("add", {}))
check("missing required int -> -32602", rc == 0 and r["error"]["code"] == -32602, (rc, r))
rc, r = one(DEMO, call("greet", {}))
check("missing required String -> -32602 (was crash)", rc == 0 and r["error"]["code"] == -32602, (rc, r))
rc, r = one(DEMO, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "ping"}})
check("arguments omitted on no-arg tool ok", rc == 0 and r["result"]["content"][0]["text"] == "pong", r)
rc, r = one(DEMO, call("add", [1, 2]))
check("arguments as array -> -32602", rc == 0 and r["error"]["code"] == -32602, r)
rc, r = one(DEMO, call("add", {"a": "x"}))
check("wrong arg type -> -32602", rc == 0 and r["error"]["code"] == -32602, r)

# --- id / jsonrpc validation
for bad_id in (True, {}, []):
    rc, r = one(DEMO, {"jsonrpc": "2.0", "id": bad_id, "method": "ping"})
    check(f"id={bad_id!r} rejected", rc == 0 and r["error"]["code"] == -32600, r)
rc, r = one(DEMO, {"jsonrpc": "1.0", "id": 1, "method": "ping"})
check("jsonrpc != 2.0 rejected", rc == 0 and r["error"]["code"] == -32600, r)
rc, r = one(DEMO, {"id": 1, "method": "ping"})
check("missing jsonrpc rejected", rc == 0 and r["error"]["code"] == -32600, r)
rc, r = one(DEMO, {"jsonrpc": "2.0", "id": 0, "method": "ping"})
check("id 0 echoed", rc == 0 and r["id"] == 0 and r["result"] == {}, r)

# --- demo divide: INT_MIN / -1 must not trap
rc, r = one(DEMO, call("divide", {"a": -2147483648, "b": -1}))
check("INT_MIN/-1 -> isError, no SIGFPE", rc == 0 and r["result"]["isError"] is True, (rc, r))

# --- schema carries defaults
rc, r = one(DEMO, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
tools = {t["name"]: t for t in r["result"]["tools"]}
check("schema has default for optional param", tools["add"]["inputSchema"]["properties"]["b"].get("default") == 10, tools["add"])
check("schema keeps description next to default", tools["add"]["inputSchema"]["properties"]["b"].get("description") == "second addend, default 10", tools["add"])

# --- framing
rc, out, _ = run(DEMO, [], raw='{"jsonrpc":"2.0","id":1,"method":"ping"}')           # no trailing newline
check("EOF without newline still answered", rc == 0 and len(out) == 1, out)
rc, out, _ = run(DEMO, [], raw='\r\n\n{"jsonrpc":"2.0","id":1,"method":"ping"}\r\n\n')
check("blank lines / CRLF", rc == 0 and len(out) == 1, out)
rc, out, _ = run(DEMO, [], raw='[{"jsonrpc":"2.0","id":1,"method":"ping"}]\n')
check("batch array -> -32600 (MCP stdio: no batching)", rc == 0 and out[0]["error"]["code"] == -32600, out)

# --- unicode / escapes survive round trip into valid JSON
rc, r = one(DEMO, call("greet", {"name": 'Kö"ni\n\u2603 \U0001F600'}))
check("unicode/escapes -> valid JSON result", rc == 0 and r["result"]["isError"] is False, r)

# --- c3dev
import shutil, tempfile
C3C = os.environ.get("C3C") or shutil.which("c3c")
assert C3C, "c3c not found: put it on PATH or set C3C"
C3 = os.path.dirname(os.path.realpath(C3C))      # install dir, stdlib in <C3>/lib/std
os.environ["C3C"] = C3C
os.environ["C3DEV_ROOT"] = C3                     # c3dev may only touch files under this root
env = dict(os.environ)
def grep(pattern, d, **kw):
    a = {"pattern": pattern, "dir": d}; a.update(kw)
    return one(C3DEV, call("c3_grep", a))
rc, r = grep("--version", C3 + "/lib/std/io")
t = r["result"]["content"][0]["text"]
check("pattern '--version' is a pattern, not a grep option", "GNU grep" not in t, t)
rc, r = grep("unmarshal", C3 + "/lib/std/encoding", max_lines=-5)
check("negative max_lines clamped", "[exit code 0]" in r["result"]["content"][0]["text"], r)
rc, r = grep("fn String", C3 + "/lib/std/core")
t = r["result"]["content"][0]["text"]
check("String? result not double-encoded", not t.startswith(chr(34)) and "\n[exit code" in t, t[-120:])
rc, r = one(C3DEV, call("c3_check", {"files": [C3 + "/nope/y.c3"], "c3c": "git"}))
t = r["result"]["content"][0]["text"]
check("c3_check ignores a 'c3c' argument (no arbitrary binary)", "usage: git" not in t.lower() and "git" not in t.split("[exit")[0].lower()[:80], t[:200])
t0 = time.time()
rc, r = one(C3DEV, call("c3_grep", {"pattern": ".", "dir": C3 + "/lib/std", "max_lines": 1000}))
check("large output is truncated, call returns", time.time() - t0 < 15 and r["result"]["isError"] is False, time.time() - t0)

# --- c3dev confinement (review finding: --trust=full + $exec was remote code execution)
def text_of(r): return r["result"]["content"][0]["text"]
root = tempfile.mkdtemp()
marker = os.path.join(root, "pwned")
evil = os.path.join(root, "evil.c3")
open(evil, "w").write('module evil;\n$exec("touch", { "%s" });\nfn void main() {}\n' % marker)
os.environ["C3DEV_ROOT"] = root
rc, r = one(C3DEV, call("c3_check", {"files": ["--trust=full", evil]}))
check("c3_check rejects an option argument (--trust=full)", r["result"]["isError"] and not os.path.exists(marker), r)
rc, r = one(C3DEV, call("c3_check", {"files": [evil]}))
check("c3_check never runs $exec (trust=none), baseline", not os.path.exists(marker), r)
# positive control: the SAME file does execute when the compiler is run with full trust,
# so the two checks above cannot pass just because the payload is broken
subprocess.run([C3C, "compile-only", "--trust=full", evil], capture_output=True, timeout=60)
check("control: payload does execute under --trust=full", os.path.exists(marker))
os.remove(marker)
for bad, why in (("/etc/passwd", "absolute path outside root"), (root + "/../etc/x.c3", "dot-dot"), ("-x.c3", "leading dash"), ("", "empty")):
    rc, r = one(C3DEV, call("c3_check", {"files": [bad]}))
    check("c3_check rejects " + why, r["result"]["isError"] is True and ("not allowed" in text_of(r) or "outside" in text_of(r)), r)
    rc, r = one(C3DEV, call("c3_grep", {"pattern": "x", "dir": bad}))
    check("c3_grep rejects " + why, r["result"]["isError"] is True and ("not allowed" in text_of(r) or "outside" in text_of(r)), r)
rc, r = one(C3DEV, call("c3_check", {"files": []}))
check("c3_check rejects an empty file list", r["result"]["isError"] is True, r)
os.symlink("/etc/passwd", os.path.join(root, "leak.c3"))
rc, r = one(C3DEV, call("c3_grep", {"pattern": "root", "dir": root}))
check("c3_grep does not follow a symlink out of the root", "root:" not in text_of(r), text_of(r)[:200])
fifo = os.path.join(root, "fifo.c3"); os.mkfifo(fifo)
t0 = time.time()
rc, r = one(C3DEV, call("c3_grep", {"pattern": "x", "dir": root}))
check("c3_grep skips a FIFO instead of hanging", time.time() - t0 < 10, time.time() - t0)

# --- protocol edge cases found by review
rc, out, err = run(DEMO, [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-01-01"}})])
check("unsupported protocolVersion -> server answers with its own supported version", out[0]["result"]["protocolVersion"] == "2025-06-18", out)
big = '{"jsonrpc":"2.0","id":1,"method":"ping","d":"' + "a" * (5 * 1024 * 1024) + '"}\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
rc, out, err = run(DEMO, None, raw=big, timeout=60)
check("5 MB line: server survives, parse errors, later request still answered",
      rc == 0 and out[-1].get("id") == 2 and "result" in out[-1] and all(o.get("error", {}).get("code") == -32700 for o in out[:-1]), out[-2:])

sys.exit(1 if fails else 0)
