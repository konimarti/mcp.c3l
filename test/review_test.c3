module mcp_review_fx;
import mcp, std::thread;

// Adversarial tests for the timeout / worker-thread path (src/mcp/call.c3).
// Written during the review of call.c3; each test targets one specific way it could break.

excuse BOOM;

fn String edge(int ms) @Timeout(100) { thread::sleep_ms(ms); return "done"; }
fn String? faulty() @Timeout(500) { return BOOM~; }
fn String empty() @Timeout(500) => "";
fn String big() @Timeout(2000)
{
	DString d = dstring::temp();
	for (int i = 0; i < 100_000; i++) d.append("0123456789");   // 1 MB
	return d.str_view();
}
fn mcp::ToolResult soft_error() @Timeout(500) => mcp::error("nope");
fn String untimed(int ms) @Timeout(0) { thread::sleep_ms(ms); return "inline"; }

fn mcp::Server make()
{
	mcp::Server s = mcp::new_server("r", "0");
	s.@tool(edge);
	s.@tool(faulty);
	s.@tool(empty);
	s.@tool(big);
	s.@tool(soft_error);
	s.@tool(untimed);
	return s;
}

fn String call(mcp::Server* s, String name, String args)
{
	return s.handle(tmem, string::tformat(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}`, name, args));
}

fn void drain()
{
	// wait (bounded) until every abandoned worker has finished and released its job
	for (int i = 0; i < 100 && mcp::g_stuck.load() != 0; i++) thread::sleep_ms(50);
	assert(mcp::g_stuck.load() == 0, "abandoned workers did not drain");
}


module mcp_review @test;
import mcp, mcp_review_fx, std::thread, std::io;

// 1) The decisive race: the tool finishes at the same moment the caller gives up.
//    Either outcome is fine; a crash, hang, double free or leak is not.
fn void test_boundary_race_no_crash_no_leak()
{
	@assert_leak()
	{
		mcp::Server s = mcp_review_fx::make();
		defer s.free();
		int ok, timed_out;
		for (int i = 0; i < 300; i++)
		{
			@pool()
			{
				String r = mcp_review_fx::call(&s, "edge", string::tformat(`{"ms":%d}`, 94 + (i % 12)));   // 94..105 ms vs 100 ms limit
				if (r.contains(`"done"`))
				{
					ok++;
				}
				else if (r.contains("timed out"))
				{
					timed_out++;
				}
				else
				{
					assert(false, "unexpected: %s", r);
				}
				// a timeout adds a stuck worker; keep below MAX_STUCK so the loop keeps testing the race
				if (mcp::g_stuck.load() >= mcp::MAX_STUCK - 1) mcp_review_fx::drain();
			};
		}
		mcp_review_fx::drain();
		io::printfn("    boundary race: %d finished in time, %d timed out", ok, timed_out);
		assert(ok + timed_out == 300);
	};
}

// 2) Fault, soft error, empty and 1 MB results travel through the worker's heap copies intact.
fn void test_result_kinds_through_worker_thread()
{
	@assert_leak()
	{
		mcp::Server s = mcp_review_fx::make();
		defer s.free();
		@pool()
		{
			String r = mcp_review_fx::call(&s, "faulty", "{}");
			assert(r.contains(`"isError":true`) && r.contains("BOOM"), "got %s", r);
			r = mcp_review_fx::call(&s, "soft_error", "{}");
			assert(r.contains(`"isError":true`) && r.contains("nope"), "got %s", r);
			r = mcp_review_fx::call(&s, "empty", "{}");
			assert(r.contains(`"text":""`) && r.contains(`"isError":false`), "got %s", r);
			r = mcp_review_fx::call(&s, "big", "{}");
			assert(r.len > 1_000_000 && r.contains(`"isError":false`), "len %d", r.len);
		};
	};
}

// 3) Server freed while an abandoned worker is still running must not crash or leak.
fn void test_free_server_with_stuck_worker()
{
	@assert_leak()
	{
		mcp::Server s = mcp_review_fx::make();
		@pool()
		{
			String r = mcp_review_fx::call(&s, "edge", `{"ms":400}`);
			assert(r.contains("timed out"), "got %s", r);
		};
		s.free();            // worker is still sleeping, the registry is gone
		mcp_review_fx::drain();
	};
}

// 4) Behaviour at the stuck cap, written down as a test so it is a decision and not an accident:
//    timed tools are refused, @Timeout(0) tools still run inline, and the server recovers.
fn void test_cap_refuses_timed_tools_but_not_untimed_and_recovers()
{
	@assert_leak()
	{
		mcp::Server s = mcp_review_fx::make();
		defer s.free();
		@pool()
		{
			// workers sleep 2 s: they must outlive MAX_STUCK timeouts of 100 ms on a slow shared CI runner
			for (int i = 0; i < mcp::MAX_STUCK; i++) assert(mcp_review_fx::call(&s, "edge", `{"ms":2000}`).contains("timed out"));
			assert(mcp_review_fx::call(&s, "empty", "{}").contains("still stuck"));              // refused
			assert(mcp_review_fx::call(&s, "untimed", `{"ms":1}`).contains("inline"));           // not affected
		};
		mcp_review_fx::drain();
		@pool()
		{
			assert(mcp_review_fx::call(&s, "empty", "{}").contains(`"isError":false`));          // recovered
		};
	};
}
