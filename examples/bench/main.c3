module bench;
import mcp, std::io, std::time, std::thread, std::encoding::json, std::collections::object;

// Micro benchmark of the core: Server.handle(), no I/O. Run in a release build:
//   c3c build bench -O3 --safe=no        (and compare with the default debug build)
// Prints ns/request per scenario. Every scenario is checked once for a sane reply first, so a
// fast error path cannot masquerade as a fast success.

enum Color { RED, GREEN, BLUE }
struct Point { int x; int y; }
struct Shape { String name; Point origin; Color color; Point[] corners; }

fn int add(int a, int b = 1) => a + b;
fn String paint(Color c) => Color::names[c.ordinal];
fn int count(Shape s) => (int)s.corners.len;
fn long total(int[] xs) { long t; foreach (x : xs) t += x; return t; }
fn String echo(String text) => text;
fn int slow_add(int a, int b = 1) @Timeout(1000) => a + b;
fn int bounded(int n @Min(0) @Max(100) = 5) => n;

struct Scenario { String name; String request; String expect; }

const int WARMUP = 2000;

fn String build_total_request(int n)
{
	DString d = dstring::new(mem);
	d.append(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"total","arguments":{"xs":[`);
	for (int i = 0; i < n; i++)
	{
		if (i) d.append(",");
		d.appendf("%d", i);
	}
	d.append("]}}}");
	return d.str_view();
}

fn String build_echo_request(int n)
{
	DString d = dstring::new(mem);
	d.append(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"`);
	for (int i = 0; i < n; i++) d.append("x");
	d.append(`"}}}`);
	return d.str_view();
}

fn String build_shape_request(int n)
{
	DString d = dstring::new(mem);
	d.append(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"count","arguments":{"s":{"name":"sq","origin":{"x":1,"y":2},"color":"RED","corners":[`);
	for (int i = 0; i < n; i++)
	{
		if (i) d.append(",");
		d.append(`{"x":1,"y":2}`);
	}
	d.append("]}}}}");
	return d.str_view();
}

fn void run(mcp::Server* s, Scenario sc, int iters)
{
	String first;
	@pool() { first = sc.request.len ? s.handle(mem, sc.request).copy(mem) : ""; };
	if (!first.contains(sc.expect))
	{
		io::printfn("%-34s  BAD REPLY (expected '%s'): %s", sc.name, sc.expect, first);
		return;
	}
	for (int i = 0; i < WARMUP; i++) @pool() { (void)s.handle(tmem, sc.request); };
	Clock c = clock::now();
	for (int i = 0; i < iters; i++) @pool() { (void)s.handle(tmem, sc.request); };
	NanoDuration d = c.to_now();
	double ns = (double)d / iters;
	io::printfn("%-34s %10.0f ns/req  %9.0f req/s   (req %d B -> reply %d B)", sc.name, ns, 1e9 / ns, sc.request.len, first.len);
}

// Floor for any JSON-RPC server built on std::encoding::json: parse the request once, and
// parse + marshal it (what a handler that re-serialises its arguments pays).
fn void baseline(String name, String request, int iters)
{
	for (int i = 0; i < WARMUP; i++) @pool() { (void)json::parse(tmem, request); };
	Clock c = clock::now();
	for (int i = 0; i < iters; i++) @pool() { (void)json::parse(tmem, request); };
	double parse_ns = (double)c.to_now() / iters;
	c = clock::now();
	for (int i = 0; i < iters; i++) @pool() { Object*? o = json::parse(tmem, request); if (try o) (void)json::marshal(tmem, o); };
	double both_ns = (double)c.to_now() / iters;
	io::printfn("%-34s %10.0f ns parse   %10.0f ns parse+marshal   (floor, not a server)", name, parse_ns, both_ns);
}

fn void main()
{
	mcp::Server s = mcp::new_server("bench", "0");
	defer s.free();
	s.@tool(add);
	s.@tool(paint);
	s.@tool(count);
	s.@tool(total);
	s.@tool(echo);
	s.@tool(slow_add);
	s.@tool(bounded);

	String hdr = `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":`;
	Scenario[] scenarios = {
		{ "ping", `{"jsonrpc":"2.0","id":1,"method":"ping"}`, `"result":{}` },
		{ "initialize", `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`, "protocolVersion" },
		{ "tools/list (7 tools)", `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`, `"tools"` },
		{ "call add (2 ints)", string::format(mem, `%s{"name":"add","arguments":{"a":1,"b":2}}}`, hdr), `"text":"3"` },
		{ "call add (default b)", string::format(mem, `%s{"name":"add","arguments":{"a":1}}}`, hdr), `"text":"2"` },
		{ "call bounded (@Min/@Max)", string::format(mem, `%s{"name":"bounded","arguments":{"n":7}}}`, hdr), `"text":"7"` },
		{ "call paint (enum)", string::format(mem, `%s{"name":"paint","arguments":{"c":"GREEN"}}}`, hdr), "GREEN" },
		{ "call echo (10 B)", build_echo_request(10), `"isError":false` },
		{ "call echo (10 KB)", build_echo_request(10000), `"isError":false` },
		{ "call total (10 ints)", build_total_request(10), `"text":"45"` },
		{ "call echo (100 KB)", build_echo_request(100000), `"isError":false` },
		{ "call total (10000 ints)", build_total_request(10000), `"text":"49995000"` },
		{ "call total (1000 ints)", build_total_request(1000), `"text":"499500"` },
		{ "call count (struct, 1 corner)", build_shape_request(1), `"text":"1"` },
		{ "call count (struct, 100 corners)", build_shape_request(100), `"text":"100"` },
		{ "call slow_add (@Timeout thread)", string::format(mem, `%s{"name":"slow_add","arguments":{"a":1,"b":2}}}`, hdr), `"text":"3"` },
		{ "error: missing argument", string::format(mem, `%s{"name":"add","arguments":{}}}`, hdr), "missing required" },
		{ "error: unknown method", `{"jsonrpc":"2.0","id":1,"method":"nope"}`, "-32601" },
		{ "notification (no reply)", `{"jsonrpc":"2.0","method":"notifications/initialized"}`, "" },
	};
	io::printfn("mcp-c3 core benchmark (Server.handle, no I/O)");
	baseline("json floor: add request", string::format(mem, `%s{"name":"add","arguments":{"a":1,"b":2}}}`, hdr), 20000);
	baseline("json floor: echo 10 KB", build_echo_request(10000), 5000);
	baseline("json floor: total 1000 ints", build_total_request(1000), 5000);
	baseline("json floor: count 100 corners", build_shape_request(100), 5000);
	foreach (sc : scenarios)
	{
		int iters = sc.request.len > 50000 ? 200 : (sc.request.len > 5000 ? 2000 : 20000);
		if (sc.name == "call slow_add (@Timeout thread)") iters = 5000;
		run(&s, sc, iters);
	}
}
