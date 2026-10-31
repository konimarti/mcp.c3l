module demo;
import mcp, std::thread;

excuse DIVIDE_BY_ZERO;

fn int add(int a @Desc("first addend"), int b @Desc("second addend, default 10") = 10)
	@Desc("Add two integers") => a + b;

fn String greet(String name @Desc("who to greet"), bool shout = false)
	@Desc("Greet someone") => shout ? "HELLO" : "hello";

fn double half(double x) @Desc("Half of x") => x / 2;

fn int? divide(int a, int b) @Desc("Integer division; fails on zero")
{
	if (b == 0 || (a == int::min && b == -1)) return DIVIDE_BY_ZERO~;  // INT_MIN / -1 traps in hardware
	return a / b;
}

fn int sum(int[] xs) @Desc("Sum of a list of integers")
{
	int total;
	foreach (x : xs) total += x;
	return total;
}

fn void noop() @Desc("Returns nothing") {}

fn String ping() @Desc("No-argument tool") => "pong";

// constraints, annotations, custom results
fn String dice(int sides @Desc("number of sides") @Min(2) @Max(100) = 6, String mood @OneOf("calm,wild") = "calm")
	@Desc("Pretend to roll a die") @Title("Dice roller") @ReadOnly @Idempotent @ClosedWorld
	=> sides > 6 ? "big roll" : "small roll";

fn mcp::ToolResult check_disk(int percent_full @Desc("disk usage in percent"))
	@Desc("Custom error text: reports full above 90%") @NonDestructive
{
	if (percent_full > 90) return mcp::error("disk is almost full");
	return mcp::text("disk ok");
}

// enum and struct parameters: schema, validation and decoding come from the types
enum Color { RED, GREEN, BLUE }
struct Point { int x @Desc("horizontal"); int y @Desc("vertical"); }

fn String tint(Color color @Desc("a color")) @Desc("Name of a color") => Color::names[color.ordinal];

fn Point shift(Point p @Desc("start point"), Point by @Desc("offset"))
	@Desc("Add two points") => { .x = p.x + by.x, .y = p.y + by.y };

// timeouts: this tool is cut off after 300 ms (the worker thread is abandoned)
fn String sleepy(int ms @Min(0) @Max(5000) @Desc("how long to sleep")) @Desc("Sleeps, to demonstrate @Timeout") @Timeout(300)
{
	thread::sleep_ms(ms);
	return "woke up";
}

fn void main()
{
	mcp::Server s = mcp::new_server("c3-demo", "0.1.0");
	s.@tool(add);
	s.@tool(greet);
	s.@tool(half);
	s.@tool(divide);
	s.@tool(sum);
	s.@tool(ping);
	s.@tool(noop);
	s.@tool(dice);
	s.@tool(check_disk);
	s.@tool(tint);
	s.@tool(shift);
	s.@tool(sleepy);
	s.serve_stdio();
}
