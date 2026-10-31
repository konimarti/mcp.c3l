module mcp_leak @test;
import mcp, mcp_fixtures, std::io;

// Memory-leak tests. `@assert_leak()` swaps in a tracking allocator for `mem` and aborts the
// process (with an allocation report) if anything allocated inside the scope is still alive at
// the end. Each test is therefore all-or-nothing: a leak fails the whole `c3c test` run.
//
// Contract under test:
//   * registry (schemas, defaults, required, tool list) lives on `mem`, freed by Server.free()
//   * everything per request lives on the temp allocator inside @pool()

fn void test_registry_lifecycle_no_leak()
{
	@assert_leak()
	{
		mcp::Server s = mcp_fixtures::make();
		s.free();
	};
}

fn void test_empty_server_no_leak()
{
	@assert_leak()
	{
		mcp::Server s = mcp::new_server("x", "0");
		s.free();
	};
}

fn void test_every_request_kind_no_leak()
{
	@assert_leak()
	{
		mcp::Server s = mcp_fixtures::make();
		defer s.free();
		mcp_fixtures::run_all(&s);
	};
}

fn void test_many_requests_no_growth()
{
	@assert_leak()
	{
		mcp::Server s = mcp_fixtures::make();
		defer s.free();
		for (int i = 0; i < 2000; i++) mcp_fixtures::run_all(&s);
	};
}

fn void test_double_free_is_safe()
{
	@assert_leak()
	{
		mcp::Server s = mcp_fixtures::make();
		s.free();
		s.free();   // fields cleared by the first call: must not crash or double free
	};
}
