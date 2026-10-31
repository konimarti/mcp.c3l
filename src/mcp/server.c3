module mcp;
import std::io, std::collections::object, std::encoding::json;

// Transport-agnostic protocol core (JSON-RPC 2.0 / MCP tools).
// `Server.handle` maps one request string to one response string. It never fails and
// does no I/O, so it is unit-testable and reusable behind any transport.

const int ERR_PARSE = -32700;
const int ERR_INVALID_REQUEST = -32600;
const int ERR_METHOD_NOT_FOUND = -32601;
const int ERR_INVALID_PARAMS = -32602;

// NOTE: payload-sized strings are joined with DString.append, never string::format("%s"):
// printf-style formatting costs ~7 ns/byte (10 KB: 69 us) against ~0.25 us for a plain append.
fn String result_msg(Allocator a, String id, String result) @private
{
	DString out = dstring::new(a);
	out.append(`{"jsonrpc":"2.0","id":`);
	out.append(id);
	out.append(`,"result":`);
	out.append(result);
	out.append("}");
	return out.str_view();
}

fn String error_msg(Allocator a, String id, int code, String message) @private
	=> string::format(a, `{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}`, id, code, json::marshal(a, message));

<*
 Handle one JSON-RPC message.
 @return "a JSON response, or an empty string when no response is due (notifications)"
*>
fn String Server.handle(&self, Allocator a, String msg)
{
	Object*? req = json::parse(a, msg);
	if (catch req) return error_msg(a, "null", ERR_PARSE, "parse error");
	if (!req.is_map()) return error_msg(a, "null", ERR_INVALID_REQUEST, "invalid request");

	// id must be string, number or null (JSON-RPC 2.0 s4.1); a missing id marks a notification
	bool is_request = req.has_key("id");
	String id = "null";
	if (try idobj = req.get("id"))
	{
		if (!(idobj.is_string() || idobj.is_int() || idobj.is_float() || idobj.is_null()))
		{
			return error_msg(a, "null", ERR_INVALID_REQUEST, "invalid id");
		}
		id = json::marshal(a, idobj);
	}

	bool version_ok = false;
	if (try version = req.get_string("jsonrpc")) version_ok = version == "2.0";
	String method = "";
	bool has_method = false;
	if (try m = req.get_string("method"))
	{
		method = m;
		has_method = true;
	}
	if (!version_ok || !has_method)
	{
		return is_request ? error_msg(a, id, ERR_INVALID_REQUEST, "invalid request") : "";
	}

	// Notifications never get a reply, whatever the method (JSON-RPC 2.0 s4.1).
	if (!is_request) return "";

	// params, when present, must be an object; anything else is rejected up front so no
	// handler ever sees a non-map (Object.get_string would abort the process).
	Object* params = null;
	if (try p = req.get("params"))
	{
		if (!p.is_null())
		{
			if (!p.is_map()) return error_msg(a, id, ERR_INVALID_PARAMS, "params must be an object");
			params = p;
		}
	}

	switch (method)
	{
		case "initialize":
			return result_msg(a, id, self.initialize_result(a, params));
		case "ping":
			return result_msg(a, id, "{}");
		case "tools/list":
			return result_msg(a, id, self.tools_list(a));
		case "tools/call":
			if (!params) return error_msg(a, id, ERR_INVALID_PARAMS, "missing params");
			return self.tools_call(a, id, params);
		default:
			return error_msg(a, id, ERR_METHOD_NOT_FOUND, "method not found");
	}
}

fn String Server.initialize_result(&self, Allocator a, Object* params)
{
	String version = SERVER_PROTOCOL_VERSION;
	if (params)
	{
		String? requested = params.get_string("protocolVersion");
		if (try requested)
		{
			foreach (v : SUPPORTED_VERSIONS) { if (v == requested) version = v; }
		}
	}
	String instructions = "";
	if (self.instructions.len > 0) instructions = string::format(a, `,"instructions":%s`, json::marshal(a, self.instructions));
	return string::format(a, `{"protocolVersion":%s,"capabilities":{"tools":{}},"serverInfo":{"name":%s,"version":%s}%s}`,
		json::marshal(a, version), json::marshal(a, self.name), json::marshal(a, self.version), instructions);
}

fn String Server.tools_list(&self, Allocator a)
{
	DString out = dstring::new(a);
	out.append(`{"tools":[`);
	foreach (i, &t : self.tools)
	{
		if (i > 0) out.append(",");
		out.appendf(`{"name":%s`, json::marshal(a, t.name));
		if (t.title.len) out.appendf(`,"title":%s`, json::marshal(a, t.title));
		out.appendf(`,"description":%s`, json::marshal(a, t.description));
		out.append(`,"inputSchema":`);
		out.append(t.input_schema);
		if (t.annotations.len)
		{
			out.append(`,"annotations":`);
			out.append(t.annotations);
		}
		out.append("}");
	}
	out.append("]}");
	return out.str_view();
}

fn String Server.tools_call(&self, Allocator a, String id, Object* params)
{
	String? name = params.get_string("name");
	if (catch name) return error_msg(a, id, ERR_INVALID_PARAMS, "missing tool name");
	Tool* t = self.find_tool(name);
	if (!t) return error_msg(a, id, ERR_INVALID_PARAMS, "unknown tool");

	// arguments: absent/null -> {}; otherwise must be an object containing every required name
	String args = "{}";
	Object* argobj = null;
	if (try ao = params.get("arguments"))
	{
		if (!ao.is_null())
		{
			if (!ao.is_map()) return error_msg(a, id, ERR_INVALID_PARAMS, "arguments must be an object");
			argobj = ao;
			args = json::marshal(a, ao);
		}
	}
	Object* req_names = t.required_obj;
	if (req_names)
	{
		for (sz i = 0; i < req_names.get_len(); i++)
		{
			String? key = req_names.get_string_at(i);
			if (try key)
			{
				if (!argobj || !argobj.has_key(key))
				{
					return error_msg(a, id, ERR_INVALID_PARAMS, string::format(a, "missing required argument: %s", key));
				}
			}
		}
	}

	// Constraints from @Min/@Max/@OneOf are enforced here, not only advertised.
	if (argobj)
	{
		String bad = t.check_constraints(a, argobj);
		if (bad.len) return error_msg(a, id, ERR_INVALID_PARAMS, bad);
	}

	// A tool that fails (fault) -> result with isError (the model sees it and can recover).
	// Undecodable arguments (INVALID_PARAMS) -> protocol error -32602.
	int timeout_ms = t.timeout_ms >= 0 ? t.timeout_ms : self.default_timeout_ms;
	ToolResult? res = run_with_timeout(a, t, t.name, args, timeout_ms);
	bool failed = false;
	String text;
	if (catch excuse = res)
	{
		if (excuse == INVALID_PARAMS) return error_msg(a, id, ERR_INVALID_PARAMS, "invalid arguments");
		failed = true;
		text = excuse.description;
	}
	else
	{
		text = res.text;
		failed = res.is_error;
	}
	DString out = dstring::new(a);
	out.append(`{"content":[{"type":"text","text":`);
	out.append(json::marshal(a, text));
	out.append(failed ? `}],"isError":true}` : `}],"isError":false}`);
	return result_msg(a, id, out.str_view());
}

<*
 Validate a JSON value against one node of a tool's own schema: type, required members,
 nested properties and array items, minimum/maximum, enum. Returns "" when fine, else a message
 for a -32602 error. `path` names the value ("cfg.port", "xs[2]"); "" is the arguments object.
 Integers outside the C type's range are not detected (decoding wraps them).
*>
fn String who_of(Allocator a, String path) @private => path.len ? string::format(a, "argument %s", path) : "arguments";

fn String validate_value(Allocator a, Object* schema, Object* v, String path, bool paths) @private
{
	if (!schema.is_map()) return "";
	String type = "";
	if (try ty = schema.get_string("type")) type = ty;

	switch (type)
	{
		case "object":
			if (!v.is_map()) return string::format(a, "%s must be an object", who_of(a, path));
			if (try req = schema.get("required"))
			{
				for (sz i = 0; i < req.get_len(); i++)
				{
					String? key = req.get_string_at(i);
					if (try key)
					{
						if (!v.has_key(key)) return string::format(a, "%s is missing required field %s", who_of(a, path), key);
					}
				}
			}
			if (try props = schema.get("properties"))
			{
				String bad = "";
				props.@each_entry(; String key, Object* p)
				{
					if (!bad.len && v.has_key(key))
					{
						if (try child = v.get(key))
						{
							bad = validate_value(a, p, child, !paths ? "" : (path.len ? string::format(a, "%s.%s", path, key) : key), paths);
						}
					}
				};
				if (bad.len) return bad;
			}
		case "array":
			if (!v.is_array()) return string::format(a, "%s must be an array", who_of(a, path));
			if (try items = schema.get("items"))
			{
				for (sz i = 0; i < v.get_len(); i++)
				{
					String bad = validate_value(a, items, v.get_at(i), paths ? string::format(a, "%s[%d]", path, i) : "", paths);
					if (bad.len) return bad;
				}
			}
		case "string":
			if (!v.is_string()) return string::format(a, "%s must be a string", who_of(a, path));
			if (try choices = schema.get("enum"))
			{
				bool found = false;
				for (sz i = 0; i < choices.get_len(); i++)
				{
					String? c = choices.get_string_at(i);
					if (try c) { if (c == v.s) found = true; }
				}
				if (!found) return string::format(a, "%s must be one of %s", who_of(a, path), json::marshal(a, choices));
			}
		case "boolean":
			if (!v.is_bool()) return string::format(a, "%s must be a boolean", who_of(a, path));
		case "integer":
			if (!(v.is_int() || (v.is_float() && v.f == (double)(long)v.f))) return string::format(a, "%s must be an integer", who_of(a, path));
			return check_range(a, schema, v, path);
		case "number":
			if (!(v.is_int() || v.is_float())) return string::format(a, "%s must be a number", who_of(a, path));
			return check_range(a, schema, v, path);
		default:
	}
	return "";
}

fn String check_range(Allocator a, Object* schema, Object* v, String path) @private
{
	double x = v.is_int() ? (double)v.i : v.f;
	if (try lo = schema.get("minimum"))
	{
		double m = lo.is_int() ? (double)lo.i : lo.f;
		if (x < m) return string::format(a, "%s must be >= %s", who_of(a, path), json::marshal(a, lo));
	}
	if (try hi = schema.get("maximum"))
	{
		double m = hi.is_int() ? (double)hi.i : hi.f;
		if (x > m) return string::format(a, "%s must be <= %s", who_of(a, path), json::marshal(a, hi));
	}
	return "";
}

<*
 Check the call's arguments against the tool's own schema (types, required fields, nested
 objects and arrays, minimum, maximum, enum). Returns "" when fine, else the message for a
 -32602 error.
*>
fn String Tool.check_constraints(&self, Allocator a, Object* args)
{
	if (!self.schema_obj) return "";
	// Fast pass without building any path strings; only a failing call pays for the message.
	String bad = validate_value(a, self.schema_obj, args, "", false);
	if (!bad.len) return "";
	return validate_value(a, self.schema_obj, args, "", true);
}
