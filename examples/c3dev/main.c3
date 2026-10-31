module c3dev;
import mcp, std::io, std::io::path, std::os::process, std::os::env;

const sz MAX_OUTPUT = 16 * 1024;

// Run a command (argv, no shell), capture stdout+stderr up to MAX_OUTPUT, append the exit code.
// Past MAX_OUTPUT the child is killed, so an endless producer cannot hang the server.
// The child is always reaped (join), so no zombie is left behind.
fn String? run_cmd(String[] cmd)
{
	Process p = process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV)!;
	defer (void)p.destroy();
	DString out = dstring::temp();
	bool truncated = false;
	char[4096] buf;
	while (true)
	{
		sz? n = p.read_stdout(&buf, buf.len);
		if (catch n) break;
		if (n == 0) break;
		sz room = MAX_OUTPUT - out.len();
		out.append((String)buf[:n > room ? room : n]);
		if (out.len() >= MAX_OUTPUT)
		{
			truncated = true;
			(void)p.terminate();
			break;
		}
	}
	int code = p.join()!;
	if (truncated) out.append("\n[output truncated, command killed]");
	out.appendf("\n[exit code %d]", code);
	return out.str_view();
}

// The compiler is NOT a tool argument (a client could otherwise run any binary):
// it comes from the C3C environment variable, default "c3c" from PATH.
fn String c3c_binary()
{
	String? v = env::tget_var("C3C");
	if (try v) { if (v.len > 0) return v; }
	return "c3c";
}

// SECURITY. This server gives an AI agent a compiler and grep on the local file system, so every
// path it receives is confined to ONE root directory: $C3DEV_ROOT, default the current directory.
// A path is rejected if it starts with '-' (would be read as a compiler/grep option, e.g.
// --trust=full turns compile-time $exec into code execution), contains "..", or is absolute
// and not under the root. The check is lexical: it does not resolve symlinks, so do not put
// symlinks that point outside the root into it. Run it as an unprivileged user regardless.
fn String root_dir()
{
	String? v = env::tget_var("C3DEV_ROOT");
	if (try v) { if (v.len > 0) return v; }
	Path? p = path::tcwd();
	if (try p) return (String)p;
	return "/nonexistent";
}

// "" if the path is acceptable, otherwise the reason (returned to the model as isError).
fn String path_error(String p)
{
	String root = root_dir();
	if (p.len == 0 || p[0] == '-' || p.contains("..")) return string::tformat("path not allowed: %s", p);
	if (p[0] == '/')
	{
		bool inside = p == root || (p.starts_with(root) && (root.ends_with("/") || p[root.len] == '/'));
		if (!inside) return string::tformat("path outside C3DEV_ROOT (%s): %s", root, p);
	}
	return "";
}

// run_cmd result -> ToolResult (a command that could not even start is a failed call).
macro ToolResult @to_result(#call)
{
	String? r = #call;
	if (catch e = r) return mcp::error(string::tformat("command failed to run: %s", e));
	return mcp::text(r);
}

fn ToolResult c3_check(String[] files @Desc("C3 source files to type-check"))
	@Desc("Type-check C3 files with c3c (compile-only, no link). Returns the compiler diagnostics and exit code.")
	@Timeout(120000)
{
	if (files.len == 0 || files.len > 64) return mcp::error("give 1 to 64 files");
	foreach (f : files) { String e = path_error(f); if (e.len) return mcp::error(e); }
	String[] argv = mem::talloc_array(String, files.len + 3);
	argv[0] = c3c_binary();
	argv[1] = "--trust=none";   // explicit: no $exec / $include, whatever the user's config says
	argv[2] = "compile-only";
	foreach (i, f : files) argv[i + 3] = f;
	return @to_result(run_cmd(argv));
}

fn ToolResult c3_grep(String pattern @Desc("extended regex, e.g. 'fn .* unmarshal'"),
	String dir @Desc("directory to search, e.g. <c3 install>/lib/std"),
	int max_lines @Desc("stop after this many matches (1..1000)") = 50)
	@Desc("Search C3 sources (*.c3) for a regex; use it to look up exact stdlib signatures instead of guessing.")
	@Timeout(30000)
{
	int limit = max_lines < 1 ? 50 : (max_lines > 1000 ? 1000 : max_lines);
	// "--" ends option parsing: a pattern like "-v" or "--file=x" stays a pattern.
	String e = path_error(dir);
	if (e.len) return mcp::error(e);
	// -r does not follow symlinks; -D skip never reads FIFOs or devices (they would hang the call).
	return @to_result(run_cmd({ "grep", "-rnE", "-D", "skip", "--include=*.c3", "-m", string::tformat("%d", limit), "--", pattern, dir }));
}

fn void main()
{
	mcp::Server s = mcp::new_server("c3dev", "0.1.0");
	s.@tool(c3_check);
	s.@tool(c3_grep);
	s.serve_stdio();
}
