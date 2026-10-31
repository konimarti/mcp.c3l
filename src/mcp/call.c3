module mcp;
import std::thread, std::time, std::atomic;

// Tool execution with an optional wall-clock timeout.
//
// timeout <= 0: the handler runs inline on the caller's allocator (no thread, no overhead).
// timeout  > 0: the handler runs on a worker thread; the caller waits at most that long.
//   On timeout the call is answered with an `isError` result and the worker is ABANDONED:
//   a thread cannot be killed safely, so a stuck tool keeps its thread until it returns or
//   the process exits. The abandoned worker owns its job and frees it itself, and it never
//   touches the caller's allocator. After MAX_STUCK abandoned workers, new timed calls are
//   refused rather than piling up threads.

// Opt-in: a tool without @Timeout runs inline on the caller's thread (no thread, no overhead).
// A worker thread is not worth paying for tools that cannot hang: measured, it adds ~0.24 ms per
// call in a debug build (34 000 handle() calls: 7.8 s inline, 15.8 s threaded), ~0.1 ms in release.
// Set Server.default_timeout_ms to protect every tool at that price.
const int DEFAULT_TIMEOUT_MS = 0;
const int MAX_STUCK = 4;

Atomic{int} g_stuck;

struct CallJob @private
{
	Allocator alloc;   // allocator of the creating thread; `mem` is per-thread in C3, so the worker must free through this
	Mutex mutex;
	ConditionVariable cond;
	bool done;
	bool abandoned;
	ToolHandler handler;
	void* target;
	String args;       // heap copies: the worker may outlive the request
	String defaults;
	String names;
	String text;       // result, heap copy
	bool is_error;
	bool failed;       // handler returned a fault
	fault err;
}

fn void CallJob.release(&self)
{
	Allocator al = self.alloc;
	if (self.args.len) alloc::free(al, self.args.ptr);
	if (self.defaults.len) alloc::free(al, self.defaults.ptr);
	if (self.names.len) alloc::free(al, self.names.ptr);
	if (self.text.len) alloc::free(al, self.text.ptr);
	self.mutex.destroy();
	self.cond.destroy();
	alloc::free(al, self);
}

fn String heap_copy(Allocator al, String s) @private => s.len ? s.copy(al) : "";

fn int run_job(void* arg) @private
{
	CallJob* j = (CallJob*)arg;
	@pool_init(j.alloc, 64 * 1024)
	{
		ToolResult? r = j.handler(tmem, j.args, j.defaults, j.names, j.target);
		if (catch e = r)
		{
			j.err = e;
			j.failed = true;
		}
		else
		{
			j.text = heap_copy(j.alloc, r.text);
			j.is_error = r.is_error;
		}
	};
	bool drop;
	(void)j.mutex.lock();
	j.done = true;
	drop = j.abandoned;
	(void)j.cond.signal();
	j.mutex.unlock();
	if (drop)
	{
		g_stuck.sub(1);
		j.release();
	}
	return 0;
}

<*
 Run a tool's handler under the tool's effective timeout.
 @param timeout_ms : "<= 0 disables the timeout"
*>
fn ToolResult? run_with_timeout(Allocator a, Tool* t, String name, String args, int timeout_ms) @private
{
	if (timeout_ms <= 0) return t.handler(a, args, t.defaults, t.names, t.target);
	if (g_stuck.load() >= MAX_STUCK)
	{
		return error(string::format(a, "tool '%s' not run: %d earlier calls are still stuck", name, MAX_STUCK));
	}

	CallJob* j = alloc::new(mem, CallJob);
	j.alloc = mem;
	j.handler = t.handler;
	j.target = t.target;
	j.args = heap_copy(j.alloc, args);
	j.defaults = heap_copy(j.alloc, t.defaults);
	j.names = heap_copy(j.alloc, t.names);
	(void)j.mutex.init();
	(void)j.cond.init();

	Thread th;
	if (catch th.create(&run_job, j))
	{
		j.release();
		return error(string::format(a, "tool '%s' not run: cannot start worker thread", name));
	}

	Clock start = clock::now();
	bool timed_out = false;
	(void)j.mutex.lock();
	while (!j.done)
	{
		long left = (long)timeout_ms - (long)(start.to_now() / 1_000_000);
		if (left <= 0)
		{
			timed_out = true;
			break;
		}
		(void)j.cond.wait_timeout(&j.mutex, (ulong)left);
	}
	if (timed_out && !j.done)
	{
		j.abandoned = true;
		g_stuck.add(1);
	}
	else
	{
		timed_out = false;
	}
	j.mutex.unlock();

	if (timed_out)
	{
		(void)th.detach();
		return error(string::format(a, "tool '%s' timed out after %d ms", name, timeout_ms));
	}
	(void)th.join();
	defer j.release();
	if (j.failed) return j.err~;
	ToolResult res = { .text = j.text.len ? j.text.copy(a) : "", .is_error = j.is_error };
	return res;
}
