# mcp.c3l

**An MCP SDK for C3.** Write a C3 function, get an MCP tool.

`mcp.c3l` is a C3 library for building [Model Context Protocol](https://modelcontextprotocol.io) servers. You write ordinary functions; types, optional parameters and descriptions are read from the code at compile time, and the JSON Schema, argument decoding and dispatch are generated from them. The result is a native binary that MCP clients can start and talk to over stdio.

```c3
import mcp;

fn int add(int a @Desc("first number"), int b @Desc("second number") = 1)
	@Desc("Add two integers") => a + b;

fn void main()
{
	mcp::Server server = mcp::new_server("hello", "0.1.0");
	server.@tool(add);          // schema, argument decoding, dispatch: derived from the signature
	server.serve_stdio();
}
```

That is the whole server. `tools/list` now advertises:

```json
{"name":"add","description":"Add two integers","inputSchema":{"type":"object","properties":{
  "a":{"type":"integer","description":"first number"},
  "b":{"type":"integer","description":"second number","default":1}},"required":["a"]}}
```

## Why

- **Little ceremony.** Tools are plain functions. There are no schema files to keep in sync with the code.
- **Native.** About 980 lines of library, no interpreter and no garbage collector. A server starts in about 2 ms (median of 40 runs on one machine).
- **Type errors at compile time.** An unsupported parameter type is a compiler error, not a surprise at runtime.
- **Tested against bad input.** Malformed JSON, wrong types, missing arguments and oversized lines get a JSON-RPC error and never crash the server. Each problem found in review has a regression test.
- **Used with a real client.** `tools/list` and `tools/call` over stdio work with Hermes Agent's MCP client.

## Install

Requires [`c3c`](https://github.com/c3lang/c3c) **0.8.5**. C3 is pre-1.0, so other versions may not compile. CI builds and tests on linux-x64 and macos-aarch64 (full suite) and windows-x64 (build, unit and protocol tests; the red-team and c3dev tests use POSIX tools); the manifest also lists linux-aarch64 and macos-x64, which are untested.

`mcp.c3l` is a regular C3 library (unpacked directory with a `manifest.json`). Put it where your project looks for libraries:

```
git clone https://github.com/konimarti/mcp.c3l deps/mcp.c3l      # or: git submodule add ...
```

`project.json` of your project:

```json
{
  "langrev": "1",
  "version": "0.1.0",
  "dependency-search-paths": [ "deps" ],
  "dependencies": [ "mcp" ],
  "sources": [ "src/**" ],
  "targets": { "myserver": { "type": "executable" } }
}
```

Put the example above into `src/main.c3`, then:

```
c3c build myserver
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | out/myserver
```

## Try the examples

```
git clone https://github.com/konimarti/mcp.c3l && cd mcp.c3l
c3c build hello
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | build/hello
```

Register it with an MCP client, e.g. Hermes: `hermes mcp add hello --command $PWD/build/hello`

Claude Desktop, Cursor and most other clients take the same thing as JSON (`mcpServers` in their config file; the path must be absolute):

```json
{ "mcpServers": { "hello": { "command": "/abs/path/to/mcp.c3l/build/hello" } } }
```

## What you get

| | |
|---|---|
| Parameters | `String`, `bool`, ints, floats, C3 `enum`s, structs (nested), slices of those |
| Optional params | any parameter with a default value |
| Returns | `void`, `String`, `mcp::ToolResult`, or anything JSON-serialisable; a fault (`T?`) becomes `isError: true` |
| Constraints | `@Min(n)`, `@Max(n)`, `@OneOf("a,b,c")`: in the schema and enforced on call |
| Timeouts | opt-in: `@Timeout(ms)` per tool (or `server.default_timeout_ms` for all); a hung tool cannot block the server |
| Metadata | `@Desc`, `@Title`, `@ReadOnly`, `@NonDestructive`, `@Idempotent`, `@ClosedWorld` |
| Instructions | `server.instructions = "..."` is sent to the client in `initialize`, so the model learns when to use your tools |
| Protocol | MCP 2025-06-18 (also 2025-03-26, 2024-11-05), tools over stdio |
| Errors | JSON-RPC error codes as in the spec; bad arguments never crash the server |

## Constraints, annotations, custom results

```c3
fn String roll(int sides @Min(2) @Max(100) = 6, String mood @OneOf("calm,wild") = "calm")
	@Desc("Pretend to roll a die") @Title("Dice roller") @ReadOnly @Idempotent => "big roll";

fn mcp::ToolResult check_disk(int percent_full)
{
	if (percent_full > 90) return mcp::error("disk is almost full");   // you choose text and isError
	return mcp::text("disk ok");
}
```

- **Constraints** go into the JSON Schema (`minimum`, `maximum`, `enum`) and are enforced by the server: a violating call gets JSON-RPC `-32602` with a readable message. `@Min`/`@Max` on a non-numeric and `@OneOf` on a non-`String` parameter are compile errors. No spaces around the commas in `@OneOf`.
- **`title` and annotations** (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) appear in `tools/list`; a hint is only sent when you set it.
- **`mcp::ToolResult`**: return `mcp::text(..)` or `mcp::error(..)` to control the message and `isError` yourself.
- Tools with the same signature but different parameter names are decoded correctly (regression test).

## Enums, structs and timeouts

```c3
import mcp, std::thread;

enum Color { RED, GREEN, BLUE }
struct Point { int x @Desc("horizontal"); int y @Desc("vertical"); }

fn Point shift(Point p, Point by) @Desc("Add two points") => { .x = p.x + by.x, .y = p.y + by.y };
fn String tint(Color color) => Color::names[color.ordinal];

fn String slow_job(int ms) @Timeout(300) { thread::sleep_ms(ms); return "done"; }
```

- **Enums** become `{"type":"string","enum":["RED","GREEN","BLUE"]}`. **Structs** become nested JSON objects; every member is required (C3 struct members have no defaults), and `@Desc` works on members. The server validates the whole argument tree against the schema (types, required fields, nested objects and array items, `@Min`/`@Max`/`@OneOf`) *before* decoding, so a missing nested field is a `-32602` error, never a silent `0`.
- **Timeouts:** each call runs on a worker thread and is answered with `isError: true` ("tool 'x' timed out after N ms") when the limit passes. Opt-in: tools without `@Timeout` run inline with no thread and no overhead (a worker thread adds about 0.1 ms per call in a release build, 0.25 ms in debug). Set `@Timeout(ms)` on tools that can hang (network, subprocess), or `server.default_timeout_ms` to protect all of them. A thread cannot be killed safely, so a timed-out tool keeps running in the background until it returns; after 4 such stuck workers new calls are refused. Do not rely on a timed-out tool having been stopped.
- Limits: an enum parameter cannot have a default value (c3c 0.8.5 crashes on it, so this is a compile error with a message); no pointers or unions as parameters; a struct or slice parameter with a default value crashes c3c 0.8.5 during compilation (use a required parameter; the enum case is caught with a message, these two are not); integers outside the C type's range are not rejected.

## Examples

- `examples/hello`: the 45-line tour.
- `examples/c3dev`: gives coding agents `c3_check` (type-check C3 with `c3c`) and `c3_grep` (look up real stdlib signatures instead of guessing).

> **Security: c3dev hands an AI agent a compiler and grep on your file system.** It is an example, not a hardened product. It confines every path to one root (`C3DEV_ROOT`, default the current directory), rejects paths that start with `-` or contain `..`, runs `c3c` with `--trust=none` and never follows symlinks out. The check is lexical, so do not keep symlinks that leave the root inside it, set `C3DEV_ROOT` to a project directory rather than `/` or `$HOME`, and run it as an unprivileged user. The `C3C` environment variable decides which binary is executed: do not let untrusted input set it.

## Limits (v0.1)

Tools and stdio only. No resources, prompts, HTTP, pagination or `structuredContent` yet. Timeouts abandon the worker rather than cancel it, and `notifications/cancelled` is ignored. Pinned to `c3c` 0.8.5; C3 is pre-1.0 and breaks between releases.

## Build and test

```
./test.sh     # unit tests, leak tests, protocol tests, red-team regressions, end-to-end
```

The script needs `c3c` on your `PATH` (or set `C3C`) and `python3`.

> **Rule of the road:** stdout is the protocol. Never print to it from a tool.

## License

MIT, see [LICENSE](LICENSE).
