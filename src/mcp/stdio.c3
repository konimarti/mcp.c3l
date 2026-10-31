module mcp;
import std::io;

// Longest accepted request line. The reader truncates longer lines (the temp arena cannot grow
// without bound); the fragments fail to parse and are answered with -32700, the server keeps running.
const sz MAX_LINE = 4 * 1024 * 1024;

// stdio transport: newline-delimited JSON-RPC (MCP spec). stdout carries protocol
// messages only; diagnostics go to stderr.

<*
 Serve on stdin/stdout until EOF. Each request gets its own temporary arena.
*>
fn void Server.serve_stdio(&self)
{
	while (true)
	{
		bool eof = false;
		@pool()
		{
			String? line = io::treadline(io::stdin(), MAX_LINE);
			if (catch err = line)
			{
				if (err != io::EOF) io::eprintfn("mcp: stdin error: %s", err.description);
				eof = true;
			}
			else if (line.len > 0)
			{
				String response = self.handle(tmem, line);
				if (response.len > 0)
				{
					io::printn(response);
					(void)io::stdout().flush();
				}
			}
		};
		if (eof) break;
	}
}
