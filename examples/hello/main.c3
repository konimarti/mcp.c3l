module hello;
import mcp;

// 1) A tool is an ordinary function. Metadata goes in @Desc(...).
fn String echo(String text @Desc("text to repeat back"))
	@Desc("Return the given text unchanged") => text;

// 2) Parameters with a default are optional. int, double, bool, String and slices work.
fn int add(int a @Desc("first number"), int b @Desc("second number") = 1)
	@Desc("Add two integers (b defaults to 1)") => a + b;

// 3) Slices become JSON arrays.
fn double mean(double[] values @Desc("numbers to average"))
	@Desc("Arithmetic mean of a list of numbers")
{
	if (values.len == 0) return 0;
	double total;
	foreach (v : values) total += v;
	return total / values.len;
}

// 4) A fault (T?) is reported to the model as a failed tool call (isError: true).
excuse EMPTY_NAME;
fn String? greet(String name @Desc("who to greet"))
	@Desc("Greet a person; fails on an empty name")
{
	if (name.len == 0) return EMPTY_NAME~;
	return string::tformat("Hello, %s!", name);
}

fn void main()
{
	mcp::Server server = mcp::new_server("hello", "0.1.0");
	defer server.free();
	server.@tool(echo);
	server.@tool(add);
	server.@tool(mean);
	server.@tool(greet);
	server.serve_stdio();       // newline-delimited JSON-RPC on stdin/stdout until EOF
}
