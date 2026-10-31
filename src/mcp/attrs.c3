module mcp;

// Metadata attributes for tools. Thin, readable aliases over @tag, which is what the
// reflection in tool.c3 reads. Use on a function (tool description) or on a parameter.
//
//   fn int add(int a @Desc("first"), int b @Desc("second") = 1) @Desc("Add two integers") => a + b;
//
// (Custom attributes cannot carry doc comments: `<* *>` is invisible to reflection in c3c 0.8.5.)
attrdef @Desc(text) = @tag("desc", text);

// Tool metadata (put on the function): human title and MCP behaviour hints. A hint is only
// advertised when you set it; the MCP defaults (not read-only, destructive, not idempotent,
// open world) apply otherwise.
attrdef @Title(text) = @tag("title", text);
attrdef @ReadOnly = @tag("readonly", "true");
attrdef @NonDestructive = @tag("nondestructive", "true");
attrdef @Idempotent = @tag("idempotent", "true");
attrdef @ClosedWorld = @tag("closedworld", "true");

// Per-tool wall-clock timeout in milliseconds (0 = none). Opt-in: without it the server default
// applies (Server.default_timeout_ms, 0 = no timeout, no worker thread). A timed-out call is answered with isError; the stuck
// worker thread cannot be killed and is abandoned.
attrdef @Timeout(ms) = @tag("timeout_ms", ms);

// Parameter constraints (put on a parameter). They end up in the JSON Schema AND are enforced
// by the server on tools/call. @Min/@Max: numeric parameters only; @OneOf("a,b,c"): String only.
attrdef @Min(v) = @tag("min", v);
attrdef @Max(v) = @tag("max", v);
attrdef @OneOf(choices) = @tag("oneof", choices);
