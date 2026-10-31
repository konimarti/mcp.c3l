module mcp;
import std::io, std::collections::object, std::encoding::json;

// Compile-time tool registration: JSON Schema from the signature, argument decoding
// into the function's `param_struct`, and the call itself.

// ---- schema -----------------------------------------------------------------

<*
 JSON Schema fragment for one parameter type. Resolved entirely at compile time;
 unsupported types are a compile error, never a runtime surprise.
*>
macro String @schema_of($Type) @private
{
	$switch:
		$case $Type == String: return `{"type":"string"}`;
		$case $Type == bool: return `{"type":"boolean"}`;
		$case $Type::kind == SIGNED_INT || $Type::kind == UNSIGNED_INT: return `{"type":"integer"}`;
		$case $Type::kind == FLOAT: return `{"type":"number"}`;
		$case $Type::kind == ENUM:
			DString eo = dstring::temp();
			eo.append(`{"type":"string","enum":[`);
			String[] ev = $Type::names;
			foreach (ei, en : ev)
			{
				if (ei > 0) eo.append(",");
				eo.append(json::marshal(tmem, en));
			}
			eo.append("]}");
			return eo.str_view();
		$case $Type::kind == STRUCT:
			// All members are required: C3 struct members have no defaults, and a missing one
			// would silently decode to zero. Describe a member with @Desc / @tag("desc", ..).
			DString so = dstring::temp();
			DString sr = dstring::temp();
			so.append(`{"type":"object","properties":{`);
			bool sfirst = true;
			$foreach $m : $Type::members:
			{
				if (!sfirst)
				{
					so.append(",");
					sr.append(",");
				}
				sfirst = false;
				so.appendf(`%s:`, json::marshal(tmem, $m.name));
				String mfrag = @schema_of($Typefrom($m.type));
				so.append(mfrag[:mfrag.len - 1]);
				$if $m.has_tag("desc"):
					so.appendf(`,"description":%s`, json::marshal(tmem, $m.get_tag("desc")));
				$endif
				so.append("}");
				sr.append(json::marshal(tmem, $m.name));
			}
			$endforeach
			so.appendf(`},"required":[%s]}`, sr.str_view());
			return so.str_view();
		$case $Type::kind == SLICE:
			return string::tformat(`{"type":"array","items":%s}`, @schema_of($Typefrom($Type::inner)));
		$default: $error "mcp: unsupported tool parameter type";
	$endswitch
}

// Invariant: every @schema_of fragment is a compact JSON object ending in '}', which is what
// lets @build_schema append "description"/"default" by dropping that last byte.
macro String @build_schema(#f) @private
{
	DString props = dstring::new(mem);
	DString req = dstring::new(mem);
	bool first_prop = true;
	bool first_req = true;
	$foreach $p : $Typeof(&#f)::params:
	{
		if (!first_prop) props.append(",");
		first_prop = false;
		props.appendf(`%s:`, json::marshal(tmem, $p.name));
		String frag = @schema_of($Typefrom($p.type));
		props.append(frag[:frag.len - 1]);
		$if $p.has_tag("desc"):
			props.appendf(`,"description":%s`, json::marshal(tmem, $p.get_tag("desc")));
		$endif
		$if $defined($p.default_value):
			props.appendf(`,"default":%s`, json::marshal(tmem, $p.default_value));
		$endif
		$if $p.has_tag("min"):
			$assert $Typefrom($p.type)::kind == SIGNED_INT || $Typefrom($p.type)::kind == UNSIGNED_INT || $Typefrom($p.type)::kind == FLOAT : "mcp: @Min needs a numeric parameter";
			props.appendf(`,"minimum":%s`, json::marshal(tmem, $p.get_tag("min")));
		$endif
		$if $p.has_tag("max"):
			$assert $Typefrom($p.type)::kind == SIGNED_INT || $Typefrom($p.type)::kind == UNSIGNED_INT || $Typefrom($p.type)::kind == FLOAT : "mcp: @Max needs a numeric parameter";
			props.appendf(`,"maximum":%s`, json::marshal(tmem, $p.get_tag("max")));
		$endif
		$if $p.has_tag("oneof"):
			$assert $Typefrom($p.type) == String : "mcp: @OneOf needs a String parameter";
			props.append(`,"enum":[`);
			String[] choices = $p.get_tag("oneof").tsplit(",");
			foreach (ci, ch : choices)
			{
				if (ci > 0) props.append(",");
				props.append(json::marshal(tmem, ch));
			}
			props.append("]");
		$endif
		props.append("}");
		$if !$defined($p.default_value):
			if (!first_req) req.append(",");
			first_req = false;
			req.appendf(`%s`, json::marshal(tmem, $p.name));
		$endif
	}
	$endforeach
	String s = string::format(mem, `{"type":"object","properties":{%s},"required":[%s]}`, props.str_view(), req.str_view());
	props.free();
	req.free();
	return s;
}

<*
 JSON array of the names of parameters without a default. Captured per function at
 registration (same reason as defaults); tools/call rejects calls that omit one.
*>
macro String @build_required(#f) @private
{
	DString out = dstring::new(mem);
	out.append("[");
	bool first = true;
	$foreach $p : $Typeof(&#f)::params:
	{
		$if !$defined($p.default_value):
			if (!first) out.append(",");
			first = false;
			out.append(json::marshal(tmem, $p.name));
		$endif
	}
	$endforeach
	out.append("]");
	String s = string::format(mem, "%s", out.str_view());
	out.free();
	return s;
}

<*
 JSON array with this function's parameter names, in order. The shared trampoline needs it:
 a function-pointer type does not carry parameter names, so two functions with the same
 signature but different names (`f(int alpha)`, `g(int beta)`) share one `param_struct`.
*>
macro String @build_names(#f) @private
{
	DString out = dstring::new(mem);
	out.append("[");
	bool first = true;
	$foreach $p : $Typeof(&#f)::params:
	{
		if (!first) out.append(",");
		first = false;
		out.append(json::marshal(tmem, $p.name));
	}
	$endforeach
	out.append("]");
	String s = string::format(mem, "%s", out.str_view());
	out.free();
	return s;
}

<*
 JSON object with the default value of every defaulted parameter. Built here, per
 function, because generic instantiations are shared between functions of equal
 signature - reading defaults inside the trampoline would mix them up.
*>
macro String @build_defaults(#f) @private
{
	DString out = dstring::new(mem);
	out.append("{");
	bool first = true;
	$foreach $p : $Typeof(&#f)::params:
	{
		$if $defined($p.default_value):
			if (!first) out.append(",");
			first = false;
			out.appendf(`%s:%s`, json::marshal(tmem, $p.name), json::marshal(tmem, $p.default_value));
		$endif
	}
	$endforeach
	out.append("}");
	String s = string::format(mem, "%s", out.str_view());
	out.free();
	return s;
}

<*
 JSON object with the MCP annotation hints set via @ReadOnly etc., or "" when none is set.
*>
macro String @build_annotations(#f) @private
{
	DString out = dstring::new(mem);
	bool first = true;
	$if $reflect(#f).has_tag("title"):
		out.appendf(`"title":%s`, json::marshal(tmem, $reflect(#f).get_tag("title")));
		first = false;
	$endif
	$if $reflect(#f).has_tag("readonly"):
		if (!first) out.append(",");
		first = false;
		out.append(`"readOnlyHint":true`);
	$endif
	$if $reflect(#f).has_tag("nondestructive"):
		if (!first) out.append(",");
		first = false;
		out.append(`"destructiveHint":false`);
	$endif
	$if $reflect(#f).has_tag("idempotent"):
		if (!first) out.append(",");
		first = false;
		out.append(`"idempotentHint":true`);
	$endif
	$if $reflect(#f).has_tag("closedworld"):
		if (!first) out.append(",");
		first = false;
		out.append(`"openWorldHint":false`);
	$endif
	String s = "";
	if (!first) s = string::format(mem, "{%s}", out.str_view());
	out.free();
	return s;
}

// ---- registration -----------------------------------------------------------

// c3c 0.8.5 crashes (segfault) as soon as reflection reads the default value of an enum
// parameter, so reject that combination with a readable error before anything reads it.
macro void @check_params(#f) @private
{
	$foreach $p : $Typeof(&#f)::params:
	{
		$if $defined($p.default_value):
			$assert $Typefrom($p.type)::kind != ENUM : "mcp: an enum parameter cannot have a default value (c3c 0.8.5 compiler bug); make it required, or use a String parameter with @OneOf";
		$endif
	}
	$endforeach
}

<*
 Register a function as a tool: `server.@tool(my_function)`.
 Metadata: `@tag("desc", "...")` on the function and on each parameter.
 Parameters with a default value are optional in the schema and filled in when absent.
*>
macro void Server.@tool(&self, #f)
{
	@check_params(#f);
	assert(self.find_tool($reflect(#f).name) == null, "mcp: tool registered twice");
	String desc = "";
	$if $reflect(#f).has_tag("desc"):
		desc = $reflect(#f).get_tag("desc");
	$endif
	int timeout_ms = -1;
	$if $reflect(#f).has_tag("timeout_ms"):
		timeout_ms = (int)$reflect(#f).get_tag("timeout_ms");
	$endif
	String title = "";
	$if $reflect(#f).has_tag("title"):
		title = $reflect(#f).get_tag("title");
	$endif
	self.tools.push({
		.name = $reflect(#f).name,
		.timeout_ms = timeout_ms,
		.title = title,
		.annotations = @build_annotations(#f),
		.description = desc,
		.input_schema = @build_schema(#f),
		.defaults = @build_defaults(#f),
		.names = @build_names(#f),
		.required = @build_required(#f),
		.handler = &trampoline{$Typeof(&#f)},
		.target = (void*)&#f,
	});
	self.tools[self.tools.len() - 1].index();
}

// Parse the per-call lookups once, at registration, instead of on every tools/call.
// A parse failure leaves the pointer null and the corresponding check is skipped (as before).
fn void Tool.index(&self)
{
	Object*? s = json::parse(mem, self.input_schema);
	if (try s) self.schema_obj = s;
	Object*? r = json::parse(mem, self.required);
	if (try r) self.required_obj = r;
}

// ---- dispatch ---------------------------------------------------------------

<*
 One instantiation per function-pointer *type*; the pointer arrives at runtime
 (lambdas cannot capture macro parameters, generics can be keyed by type).
 Per-function data (defaults) must NOT be read here - see @build_defaults.
*>
fn ToolResult? trampoline(Allocator a, String args_json, String defaults_json, String names_json, void* target) <FnT>
{
	FnT f = (FnT)target;
	$if FnT::param_struct == void::typeid:
		return @encode_result(a, f());
	$else
		// Decoding problems are the caller's fault -> INVALID_PARAMS (protocol error -32602).
		Object*? parsed = json::tparse(args_json);
		if (catch parsed) return INVALID_PARAMS~;
		Object* obj = parsed;
		if (!obj.is_map()) return INVALID_PARAMS~;
		Object*? dparsed = json::tparse(defaults_json);
		if (catch dparsed) return INVALID_PARAMS~;
		Object* defaults = dparsed;
		defaults.@each_entry(; String key, Object* value)
		{
			if (!obj.has_key(key)) obj.set(key, value);
		};
		// Re-key the arguments from this function's names to the (shared) struct's field names.
		Object*? nparsed = json::tparse(names_json);
		if (catch nparsed) return INVALID_PARAMS~;
		Object* renamed = object::new_obj(tmem);
		sz idx = 0;
		$foreach $fp : FnT::params:
		{
			String? reg = nparsed.get_string_at(idx);
			if (try reg)
			{
				if (try val = obj.get(reg)) renamed.set($fp.name, val);
			}
			idx++;
		}
		$endforeach
		$Typefrom(FnT::param_struct)? decoded = object::unmarshal{$Typefrom(FnT::param_struct)}(a, renamed);
		if (catch decoded) return INVALID_PARAMS~;
		$Typefrom(FnT::param_struct) args = decoded;
		return @encode_result(a, f(...args));
	$endif
}

// Result encoding: void -> "ok", String -> as is, anything else -> JSON.
// Optional results (T?) keep their fault; json::marshal_try (not marshal, which aborts)
// turns NaN/inf into a fault instead of killing the server.
macro ToolResult? @encode_result(Allocator a, #call) @private
{
	$switch:
		$case $Typeof(#call) == void:
			#call;
			return text("ok");
		$case ($Typeof(#call) == void?):
			#call!;
			return text("ok");
		$case $Typeof(#call) == ToolResult:
			return #call;
		$case ($Typeof(#call) == ToolResult?):
			ToolResult r = #call!;
			return r;
		$case $Typeof(#call) == String:
			return text(#call);
		$case ($Typeof(#call) == String?):
			String s = #call!;
			return text(s);
		$default:
			var result = #call;
			String s = json::marshal_try(a, result)!;
			return text(s);
	$endswitch
}
