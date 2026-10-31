module consumer;
import mcp;

// A project that uses mcp.c3l the way a user does: as a library found through
// dependency-search-paths, not by compiling this repository's own sources.
fn int add(int a @Desc("first"), int b @Desc("second") = 1) @Desc("Add two integers") => a + b;

fn void main()
{
	mcp::Server s = mcp::new_server("consumer", "0.1.0");
	defer s.free();
	s.@tool(add);
	s.serve_stdio();
}
