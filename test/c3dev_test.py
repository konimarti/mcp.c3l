"""End-to-end test of the c3dev example server. Usage: python3 test/c3dev_test.py [c3dev-binary] [c3-install-dir]"""
import json, subprocess, sys, tempfile, os

BIN = sys.argv[1] if len(sys.argv) > 1 else "build/c3dev"
import shutil
C3C = os.environ.get("C3C") or shutil.which("c3c")
assert C3C, "c3c not found: put it on PATH or set C3C"
C3 = os.path.dirname(os.path.realpath(C3C))   # install dir; the stdlib is in <C3>/lib/std

tmp = tempfile.mkdtemp()
good = os.path.join(tmp, "good.c3")
bad = os.path.join(tmp, "bad.c3")
open(good, "w").write('module good;\nimport std::io;\nfn void main() { io::printn("hi"); }\n')
open(bad, "w").write('module bad;\nfn void main() { int x = "not an int"; }\n')

def call(i, name, args):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}}

reqs = [
    {"jsonrpc": "2.0", "id": 0, "method": "tools/list"},
    call(1, "c3_check", {"files": [good]}),
    call(2, "c3_check", {"files": [bad]}),
]
reqs_grep = [call(3, "c3_grep", {"pattern": "unmarshal\\(", "dir": os.path.join(C3, "lib/std/encoding"), "max_lines": 5})]
os.environ["C3C"] = C3C
def serve(root, rs):
    os.environ["C3DEV_ROOT"] = root       # c3dev only touches files under its root
    return subprocess.run([BIN], input="\n".join(json.dumps(r) for r in rs) + "\n", capture_output=True, text=True, timeout=60)
p = serve(tmp, reqs)
q = serve(C3, reqs_grep)
p.stdout += q.stdout
assert p.returncode == 0, p.stderr
out = {r["id"]: r for r in map(json.loads, p.stdout.splitlines())}
fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + detail[:300]))
    if not cond: fails.append(name)

tools = {t["name"]: t for t in out[0]["result"]["tools"]}
check("lists c3_check and c3_grep", set(tools) == {"c3_check", "c3_grep"})
check("c3_check files is array of string", tools["c3_check"]["inputSchema"]["properties"]["files"]["items"] == {"type": "string"})
check("c3_check: only 'files' required", tools["c3_check"]["inputSchema"]["required"] == ["files"])
t1 = out[1]["result"]["content"][0]["text"]
check("good file compiles (exit code 0)", "[exit code 0]" in t1 and not out[1]["result"]["isError"], t1)
t2 = out[2]["result"]["content"][0]["text"]
check("bad file reports diagnostics + nonzero exit", "error" in t2.lower() and "[exit code 0]" not in t2, t2)
t3 = out[3]["result"]["content"][0]["text"]
check("c3_grep finds unmarshal signature", "unmarshal" in t3 and "[exit code 0]" in t3, t3)
sys.exit(1 if fails else 0)
