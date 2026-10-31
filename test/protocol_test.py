"""Protocol test for the demo server (stdlib only). Usage: python3 test/protocol_test.py [path-to-demo]"""
import json, subprocess, sys

DEMO = sys.argv[1] if len(sys.argv) > 1 else "build/demo"

def call(id_, name, args):
    return {"jsonrpc": "2.0", "id": id_, "method": "tools/call", "params": {"name": name, "arguments": args}}

REQS = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    call(3, "add", {"a": 2, "b": 40}),
    call(4, "add", {"a": 2}),                       # default b=10
    call("s5", "greet", {"name": "Koni", "shout": True}),
    call(6, "greet", {"name": "Koni"}),             # default shout=false
    call(7, "half", {"x": 5}),
    call(8, "divide", {"a": 7, "b": 0}),            # tool fault -> isError
    call(9, "sum", {"xs": [1, 2, 3, 4]}),
    call(10, "ping", {}),
    call(11, "noop", {}),                           # void return -> "ok"
    call(12, "add", {"a": "oops"}),                 # bad arg type -> isError
    call(13, "nope", {}),                           # unknown tool -> protocol error
    {"jsonrpc": "2.0", "id": 14, "method": "bogus"},
    {"jsonrpc": "2.0", "id": 15, "method": "ping"},
    call(16, "dice", {"sides": 1}),                 # below @Min -> -32602
    call(17, "dice", {"mood": "x"}),                # not in @OneOf -> -32602
    call(18, "dice", {"sides": 50, "mood": "wild"}),
    call(19, "check_disk", {"percent_full": 95}),   # ToolResult error -> isError with custom text
    call(20, "check_disk", {"percent_full": 10}),
    call(21, "tint", {"color": "BLUE"}),
    call(22, "tint", {"color": "PINK"}),            # not an enum member -> -32602
    call(23, "shift", {"p": {"x": 1, "y": 2}, "by": {"x": 10, "y": 20}}),
    call(24, "shift", {"p": {"x": 1}, "by": {"x": 10, "y": 20}}),   # missing nested field -> -32602
    call(25, "sleepy", {"ms": 10}),
    call(26, "sleepy", {"ms": 2000}),               # exceeds @Timeout(300)
]
lines = [json.dumps(r) for r in REQS] + ["not json at all"]
import time
t0 = time.time()
p = subprocess.run([DEMO], input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=20)
elapsed = time.time() - t0
assert p.returncode == 0, f"exit code {p.returncode}\n{p.stderr}"
out = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
by_id = {r["id"]: r for r in out}

def text(i):
    r = by_id[i]["result"]
    return r["content"][0]["text"], r["isError"]

failures = []
def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)

check("initialize echoes supported client version", by_id[1]["result"]["protocolVersion"] == "2025-03-26")
tools = {t["name"]: t for t in by_id[2]["result"]["tools"]}
check("tools/list has 12 tools", len(tools) == 12)
check("schema: required excludes defaulted param", tools["add"]["inputSchema"]["required"] == ["a"])
check("schema: description from tag", tools["add"]["inputSchema"]["properties"]["a"]["description"] == "first addend")
check("schema: array of integer", tools["sum"]["inputSchema"]["properties"]["xs"] == {"type": "array", "items": {"type": "integer"}})
check("schema: no-arg tool", tools["ping"]["inputSchema"]["properties"] == {} and tools["ping"]["inputSchema"]["required"] == [])
check("add 2+40", text(3) == ("42", False))
check("add default b", text(4) == ("12", False))
check("string id echoed + greet", text("s5") == ("HELLO", False))
check("greet default", text(6) == ("hello", False))
check("half", text(7) == ("2.5", False))
check("fault -> isError", text(8)[1] is True and "DIVIDE_BY_ZERO" in text(8)[0])
check("slice arg", text(9) == ("10", False))
check("no-arg tool", text(10) == ("pong", False))
check("void tool -> ok", text(11) == ("ok", False))
check("bad arg type -> -32602 protocol error", by_id[12]["error"]["code"] == -32602)
check("unknown tool -> -32602", by_id[13]["error"]["code"] == -32602)
check("unknown method -> -32601", by_id[14]["error"]["code"] == -32601)
check("ping", by_id[15]["result"] == {})
check("parse error -> -32700 with null id", by_id[None]["error"]["code"] == -32700)
check("title + annotations in tools/list", tools["dice"]["title"] == "Dice roller" and tools["dice"]["annotations"] == {"title": "Dice roller", "readOnlyHint": True, "idempotentHint": True, "openWorldHint": False})
check("no annotations when none set", "annotations" not in tools["add"] and "title" not in tools["add"])
check("destructiveHint false", tools["check_disk"]["annotations"] == {"destructiveHint": False})
check("schema: minimum/maximum/enum", tools["dice"]["inputSchema"]["properties"]["sides"]["minimum"] == 2 and tools["dice"]["inputSchema"]["properties"]["sides"]["maximum"] == 100 and tools["dice"]["inputSchema"]["properties"]["mood"]["enum"] == ["calm", "wild"])
check("@Min violated -> -32602", by_id[16]["error"]["code"] == -32602 and ">= 2" in by_id[16]["error"]["message"])
check("@OneOf violated -> -32602", by_id[17]["error"]["code"] == -32602 and "one of" in by_id[17]["error"]["message"])
check("valid constrained call", text(18) == ("big roll", False) or text(18) == ("small roll", False))
check("ToolResult error text + isError", text(19) == ("disk is almost full", True))
check("ToolResult ok", text(20) == ("disk ok", False))
check("enum param: schema", tools["tint"]["inputSchema"]["properties"]["color"] == {"type": "string", "enum": ["RED", "GREEN", "BLUE"], "description": "a color"})
check("struct param: schema", tools["shift"]["inputSchema"]["properties"]["p"] == {"type": "object", "properties": {"x": {"type": "integer", "description": "horizontal"}, "y": {"type": "integer", "description": "vertical"}}, "required": ["x", "y"], "description": "start point"})
check("enum call", text(21) == ("BLUE", False))
check("bad enum -> -32602", by_id[22]["error"]["code"] == -32602 and "one of" in by_id[22]["error"]["message"])
check("struct call returns struct JSON", json.loads(text(23)[0]) == {"x": 11, "y": 22} and text(23)[1] is False)
check("missing nested field -> -32602", by_id[24]["error"]["code"] == -32602 and "p is missing required field y" in by_id[24]["error"]["message"])
check("fast call under @Timeout", text(25) == ("woke up", False))
check("slow call -> isError timeout text", text(26) == ("tool 'sleepy' timed out after 300 ms", True))
check("notification gets no reply (26 requests + 1 garbage line = 27 responses)", len(out) == 27)
check("whole run (incl. one abandoned 2 s worker) ends in well under 2 s", elapsed < 1.8)
sys.exit(1 if failures else 0)
