module mcp_test @test;
import mcp, mcp_fixtures, std::io, std::thread;

fn void test_ping()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	assert(s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"ping"}`) == `{"jsonrpc":"2.0","id":1,"result":{}}`);
}

fn void test_notification_has_no_reply()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	assert(s.handle(tmem, `{"jsonrpc":"2.0","method":"notifications/initialized"}`) == "");
}

fn void test_call_with_default()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"add","arguments":{"a":41}}}`);
	assert(r == `{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"42"}],"isError":false}}`, "got %s", r);
}

fn void test_parse_error()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, "{nope");
	assert(r == `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}`, "got %s", r);
}

fn void test_unknown_tool_is_protocol_error()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"zzz"}}`);
	assert(r == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"unknown tool"}}`, "got %s", r);
}

fn void test_schema_generated()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	mcp::Tool* t = s.find_tool("add");
	assert(t != null);
	assert(t.input_schema == `{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer","default":1}},"required":["a"]}`, "got %s", t.input_schema);
	assert(t.description == "add");
}

fn void test_params_not_a_map_does_not_abort()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1,2]}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"params must be an object"}}`, "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":42}`);
	assert(r.starts_with(`{"jsonrpc":"2.0","id":1,"error"`), "got %s", r);
}

fn void test_notification_never_answered()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	assert(s.handle(tmem, `{"jsonrpc":"2.0","method":"ping"}`) == "");
	assert(s.handle(tmem, `{"jsonrpc":"2.0","method":"tools/list"}`) == "");
}

fn void test_missing_required_argument()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{}}}`);
	assert(r == `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"missing required argument: a"}}`, "got %s", r);
}

fn void test_toolresult_custom_error()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report","arguments":{"pct":99}}}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"full"}],"isError":true}}`, "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report_opt","arguments":{"pct":1}}}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}],"isError":false}}`, "got %s", r);
}

fn void test_annotations_and_title()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	mcp::Tool* t = s.find_tool("dice");
	assert(t != null);
	assert(t.title == "Dice");
	assert(t.annotations == `{"title":"Dice","readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}`, "got %s", t.annotations);
	assert(s.find_tool("hello").annotations == "");
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	assert(r.contains(`"title":"Dice"`) && r.contains(`"annotations":{"title":"Dice","readOnlyHint":true`), "got %s", r);
}

fn void test_constraints_in_schema()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	mcp::Tool* t = s.find_tool("dice");
	assert(t.input_schema == `{"type":"object","properties":{"sides":{"type":"integer","default":6,"minimum":2,"maximum":100},"mood":{"type":"string","default":"calm","enum":["calm","wild"]}},"required":[]}`, "got %s", t.input_schema);
}

fn void test_constraints_enforced()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dice","arguments":{"sides":1}}}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"argument sides must be >= 2"}}`, "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dice","arguments":{"sides":101}}}`);
	assert(r.contains("must be <= 100"), "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dice","arguments":{"mood":"x"}}}`);
	assert(r.contains("must be one of"), "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dice","arguments":{"sides":2,"mood":"wild"}}}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"2"}],"isError":false}}`, "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dice"}}`);
	assert(r.contains(`"isError":false`), "got %s", r);
}

fn void test_same_signature_different_param_names()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"twin_a","arguments":{"alpha":5}}}`);
	assert(r.contains(`"text":"a5"`), "got %s", r);
	r = s.handle(tmem, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"twin_b","arguments":{"beta":7}}}`);
	assert(r.contains(`"text":"b7"`), "got %s", r);
}

fn void test_enum_schema_and_call()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	assert(s.find_tool("paint").input_schema == `{"type":"object","properties":{"color":{"type":"string","enum":["RED","GREEN","BLUE"]}},"required":["color"]}`, "got %s", s.find_tool("paint").input_schema);
	assert(mcp_fixtures::call_tool(&s, "paint", `{"color":"BLUE"}`).contains(`"text":"BLUE"`));
	assert(mcp_fixtures::call_tool(&s, "paint", `{}`).contains("missing required argument: color"));
	String r = mcp_fixtures::call_tool(&s, "paint", `{"color":"PINK"}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"argument color must be one of [\"RED\",\"GREEN\",\"BLUE\"]"}}`, "got %s", r);
	r = mcp_fixtures::call_tool(&s, "paint", `{"color":2}`);
	assert(r.contains(`"error"`) && r.contains("must be a string"), "got %s", r);
}

fn void test_struct_schema()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String expect = `{"type":"object","properties":{"shape":{"type":"object","properties":{"name":{"type":"string"},"origin":{"type":"object","properties":{"x":{"type":"integer","description":"x coordinate"},"y":{"type":"integer"}},"required":["x","y"]},"color":{"type":"string","enum":["RED","GREEN","BLUE"]},"corners":{"type":"array","items":{"type":"object","properties":{"x":{"type":"integer","description":"x coordinate"},"y":{"type":"integer"}},"required":["x","y"]}}},"required":["name","origin","color","corners"]}},"required":["shape"]}`;
	assert(s.find_tool("describe").input_schema == expect, "got %s", s.find_tool("describe").input_schema);
}

fn void test_struct_call_and_validation()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = mcp_fixtures::call_tool(&s, "describe", `{"shape":{"name":"sq","origin":{"x":1,"y":2},"color":"RED","corners":[{"x":0,"y":0},{"x":1,"y":1}]}}`);
	assert(r.contains(`"text":"sq@1,2 RED corners=2"`), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "mirror", `{"p":{"x":1,"y":2}}`);
	assert(r.contains(`{\"x\":2,\"y\":1}`), "got %s", r);
	// missing nested field must NOT silently decode to 0
	r = mcp_fixtures::call_tool(&s, "describe", `{"shape":{"name":"sq","origin":{"x":1},"color":"RED","corners":[]}}`);
	assert(r.contains("argument shape.origin is missing required field y"), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "describe", `{"shape":"nope"}`);
	assert(r.contains("argument shape must be an object"), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "describe", `{"shape":{"name":"sq","origin":{"x":1,"y":2},"color":"RED","corners":[{"x":0,"y":"a"}]}}`);
	assert(r.contains("argument shape.corners[0] is missing required field y") || r.contains("must be an integer"), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "describe", `{"shape":{"name":"sq","origin":{"x":1,"y":2.5},"color":"RED","corners":[]}}`);
	assert(r.contains("argument shape.origin.y must be an integer"), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "describe", `{"shape":{"name":"sq","origin":{"x":1,"y":2},"color":"RED","corners":[{"x":0,"y":0},{"x":1}]}}`);
	assert(r.contains("argument shape.corners[1] is missing required field y"), "got %s", r);
}

fn void test_timeout_answers_with_error_and_fast_call_works()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	String r = mcp_fixtures::call_tool(&s, "slow", `{"ms":1}`);
	assert(r.contains(`"text":"done"`) && r.contains(`"isError":false`), "got %s", r);
	r = mcp_fixtures::call_tool(&s, "slow", `{"ms":400}`);
	assert(r == `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"tool 'slow' timed out after 100 ms"}],"isError":true}}`, "got %s", r);
	thread::sleep_ms(600);   // let the abandoned worker finish and free its job (leak detector)
	assert(mcp::g_stuck.load() == 0);
}

fn void test_stuck_workers_are_capped()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	for (int i = 0; i < mcp::MAX_STUCK; i++) assert(mcp_fixtures::call_tool(&s, "slow", `{"ms":500}`).contains("timed out"));
	String r = mcp_fixtures::call_tool(&s, "slow", `{"ms":1}`);
	assert(r.contains("earlier calls are still stuck") && r.contains(`"isError":true`), "got %s", r);
	thread::sleep_ms(800);
	assert(mcp::g_stuck.load() == 0);
	assert(mcp_fixtures::call_tool(&s, "slow", `{"ms":1}`).contains(`"text":"done"`));
}

fn void test_timeout_is_opt_in()
{
	mcp::Server s = mcp_fixtures::make();
	defer s.free();
	// default: no timeout, tools without @Timeout run inline and are never cut off
	assert(s.default_timeout_ms == 0);
	String r = mcp_fixtures::call_tool(&s, "nap", `{"ms":250}`);
	assert(r.contains(`"text":"napped"`) && r.contains(`"isError":false`), "got %s", r);
	assert(mcp::g_stuck.load() == 0);
	// an explicit server-wide default turns protection on for every tool
	s.default_timeout_ms = 100;
	r = mcp_fixtures::call_tool(&s, "nap", `{"ms":400}`);
	assert(r.contains("timed out after 100 ms") && r.contains(`"isError":true`), "got %s", r);
	thread::sleep_ms(600);   // let the abandoned worker finish and free its job (leak detector)
	assert(mcp::g_stuck.load() == 0);
	// @Timeout on the tool wins over the server default (here: 0 would disable, slow keeps 100)
	s.default_timeout_ms = 0;
	assert(mcp_fixtures::call_tool(&s, "slow", `{"ms":400}`).contains("timed out after 100 ms"));
	thread::sleep_ms(600);
	assert(mcp::g_stuck.load() == 0);
}
