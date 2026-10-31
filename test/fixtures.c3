module mcp_fixtures;
import mcp, std::thread;

fn int add(int a, int b = 1) @tag("desc", "add") => a + b;
fn String hello() => "hi";

fn int dice(int sides @Min(2) @Max(100) = 6, String mood @OneOf("calm,wild") = "calm")
	@Title("Dice") @ReadOnly @Idempotent @ClosedWorld @NonDestructive => sides;

// Same signature, different parameter names: must not share decoded arguments (v0.1 bug).
fn String twin_a(int alpha) => string::tformat("a%d", alpha);
fn String twin_b(int beta) => string::tformat("b%d", beta);

fn mcp::ToolResult report(int pct) => pct > 90 ? mcp::error("full") : mcp::text("ok");
fn mcp::ToolResult? report_opt(int pct) => pct > 90 ? mcp::error("full") : mcp::text("ok");

enum Color { RED, GREEN, BLUE }
struct Point { int x @Desc("x coordinate"); int y; }
struct Shape { String name; Point origin; Color color; Point[] corners; }

fn String paint(Color color) => Color::names[color.ordinal];
fn String describe(Shape shape) => string::tformat("%s@%d,%d %s corners=%d", shape.name, shape.origin.x, shape.origin.y, Color::names[shape.color.ordinal], shape.corners.len);
fn Point mirror(Point p) => { .x = p.y, .y = p.x };

fn String nap(int ms) { thread::sleep_ms(ms); return "napped"; }
fn String slow(int ms) @Timeout(100) { thread::sleep_ms(ms); return "done"; }

fn String call_tool(mcp::Server* s, String name, String args)
{
	return s.handle(tmem, string::tformat(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}`, name, args));
}

fn mcp::Server make()
{
	mcp::Server s = mcp::new_server("t", "0");
	s.@tool(add);
	s.@tool(hello);
	s.@tool(nap);
	s.@tool(dice);
	s.@tool(twin_a);
	s.@tool(twin_b);
	s.@tool(paint);
	s.@tool(describe);
	s.@tool(mirror);
	s.@tool(slow);
	s.@tool(report);
	s.@tool(report_opt);
	return s;
}

// Every request kind the server understands or must reject; used by the leak tests.
const String[] REQUESTS = {
	`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
	`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
	`{"jsonrpc":"2.0","id":2,"method":"ping"}`,
	`{"jsonrpc":"2.0","id":3,"method":"tools/list"}`,
	`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add","arguments":{"a":1,"b":2}}}`,
	`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add","arguments":{"a":1}}}`,
	`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"hello"}}`,
	`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"add","arguments":{}}}`,
	`{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"add","arguments":{"a":"x"}}}`,
	`{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"nope"}}`,
	`{"jsonrpc":"2.0","id":10,"method":"tools/call","params":[1,2]}`,
	`{"jsonrpc":"2.0","id":11,"method":"bogus"}`,
	`{"jsonrpc":"2.0","id":true,"method":"ping"}`,
	`{"jsonrpc":"1.0","id":12,"method":"ping"}`,
	`[{"jsonrpc":"2.0","id":1,"method":"ping"}]`,
	`{not json`,
	`{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"dice","arguments":{"sides":1}}}`,
	`{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"dice","arguments":{"mood":"x"}}}`,
	`{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"report","arguments":{"pct":99}}}`,
	`{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"report_opt","arguments":{"pct":5}}}`,
	`{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"twin_b","arguments":{"beta":3}}}`,
	`{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"paint","arguments":{"color":"BLUE"}}}`,
	`{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"paint","arguments":{"color":"PINK"}}}`,
	`{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"describe","arguments":{"shape":{"name":"sq","origin":{"x":1,"y":2},"color":"RED","corners":[{"x":0,"y":0},{"x":1,"y":1}]}}}}`,
	`{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"describe","arguments":{"shape":{"name":"sq","origin":{"x":1},"color":"RED","corners":[]}}}}`,
	`{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"describe","arguments":{"shape":"nope"}}}`,
	`{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"mirror","arguments":{"p":{"x":1,"y":2}}}}`,
	`{"jsonrpc":"2.0","id":36,"method":"tools/call","params":{"name":"slow","arguments":{"ms":1}}}`,
	``,
};

fn void run_all(mcp::Server* s)
{
	foreach (req : REQUESTS)
	{
		@pool()
		{
			String r = s.handle(tmem, req);
			assert(r.len >= 0);
		};
	}
}

