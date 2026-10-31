module mcp;
import std::collections::object;
import std::collections::list;

// Core types. No I/O here - see server.c3 (protocol) and stdio.c3 (transport).

const String SERVER_PROTOCOL_VERSION = "2025-06-18";
// Versions we accept from a client; anything else is answered with SERVER_PROTOCOL_VERSION.
const String[3] SUPPORTED_VERSIONS = { "2025-06-18", "2025-03-26", "2024-11-05" };

<*
 A tool handler: decode `args_json`, call the registered function, return the text
 result. A fault return means "tool failed" and becomes `isError: true`.
 `target` is the registered function pointer (see tool.c3).
*>
// Raised by a handler when the arguments cannot be decoded; becomes JSON-RPC -32602.
excuse INVALID_PARAMS;

// What a tool call produced. Tools may return this type to control `isError` and the text
// themselves: `return mcp::error("disk full");`. Returning String / any JSON-serialisable
// value / a fault still works and is converted automatically.
struct ToolResult
{
	String text;
	bool is_error;
}

fn ToolResult text(String s) => { .text = s, .is_error = false };
fn ToolResult error(String s) => { .text = s, .is_error = true };

alias ToolHandler = fn ToolResult?(Allocator, String, String, String, void*);

struct Tool
{
	String name;
	String description;
	String input_schema;   // JSON, built once at registration
	String defaults;       // JSON object of parameter defaults, captured per function at registration
	String required;       // JSON array of required parameter names, captured per function at registration
	String names;          // JSON array of this function's parameter names
	int timeout_ms;        // -1 = use Server.default_timeout_ms, 0 = none, > 0 = limit
	String title;          // optional human title (tools/list "title"), "" = none
	String annotations;    // JSON object of MCP annotation hints, "" = none
	Object* schema_obj;    // input_schema parsed once at registration (validation runs on every call)
	Object* required_obj;  // required parsed once at registration
	ToolHandler handler;
	void* target;
}

struct Server
{
	String name;
	String version;
	String instructions;      // optional usage hint for the model, sent in `initialize`; "" (default) = omitted. Borrowed, like name/version.
	int default_timeout_ms;   // applied to tools without @Timeout; 0 (default) = none
	List{Tool} tools;
}

fn Server new_server(String name, String version)
{
	Server s = { .name = name, .version = version, .default_timeout_ms = DEFAULT_TIMEOUT_MS };
	s.tools.init(mem);
	return s;
}

fn Tool* Server.find_tool(&self, String name)
{
	foreach (&t : self.tools)
	{
		if (t.name == name) return t;
	}
	return null;
}

// Release the registry (schemas and the tool list). The server owns what @tool allocated.
// A Server must not be copied after tools are registered (shallow copy would double-free).
fn void Server.free(&self)
{
	foreach (&t : self.tools)
	{
		if (t.input_schema.len) free(t.input_schema.ptr);
		if (t.defaults.len) free(t.defaults.ptr);
		if (t.names.len) free(t.names.ptr);
		if (t.required.len) free(t.required.ptr);
		if (t.annotations.len) free(t.annotations.ptr);
		if (t.schema_obj) t.schema_obj.free();
		if (t.required_obj) t.required_obj.free();
		*t = {};
	}
	self.tools.free();
}
