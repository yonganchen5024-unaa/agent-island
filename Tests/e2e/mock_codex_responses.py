#!/usr/bin/env python3
"""Local fake OpenAI Responses API for isolated Codex CLI tests. Fictional data only, no network.

Scenarios come from a JSON file: {"<KEYWORD>": [step, step, ...]}. The first request whose user
text contains KEYWORD selects a scenario; the number of function_call items already in `input`
selects the step. A step is a list of items:
  {"call": "exec_command", "args": {...}, "id": "call_x"}  becomes a function_call item,
  {"text": "..."}                                          becomes an assistant message.

Every request is appended to a JSONL log with the function_call_output items Codex sent back, which
is what proves a decision really reached the model.
"""
import argparse
import http.server
import json
import pathlib
import sys
import threading
import time
import uuid


class State:
    scenarios = {}
    log_path = None
    lock = threading.Lock()
    dump_path = None


def log(record):
    record = {"t": round(time.time(), 3), **record}
    with State.lock, open(State.log_path, "a", encoding="utf-8") as out:
        out.write(json.dumps(record, ensure_ascii=False) + "\n")


def user_text(items):
    parts = []
    for item in items:
        if isinstance(item, dict) and item.get("type", "message") == "message" and item.get("role") == "user":
            content = item.get("content")
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                parts.extend(b.get("text", "") for b in content if isinstance(b, dict))
    return "\n".join(parts)


def choose(items):
    joined = user_text(items)
    for keyword, steps in State.scenarios.items():
        if keyword in joined:
            done = sum(1 for i in items if isinstance(i, dict) and i.get("type") in ("function_call", "custom_tool_call"))
            return keyword, steps[done] if done < len(steps) else [{"text": "SCENARIO_COMPLETE"}]
    return None, [{"text": "ok"}]


def outputs(items):
    found = []
    for item in items:
        if isinstance(item, dict) and item.get("type") in ("function_call_output", "custom_tool_call_output"):
            value = item.get("output")
            found.append({"call_id": item.get("call_id"), "output": value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)})
    return found


def build_items(step):
    built = []
    for entry in step:
        if "call" in entry:
            built.append({"type": "function_call", "id": "fc_" + uuid.uuid4().hex[:16], "status": "completed",
                          "name": entry["call"], "arguments": json.dumps(entry["args"]),
                          "call_id": entry.get("id") or "call_" + uuid.uuid4().hex[:18]})
        else:
            built.append({"type": "message", "id": "msg_" + uuid.uuid4().hex[:16], "role": "assistant", "status": "completed",
                          "content": [{"type": "output_text", "text": entry["text"], "annotations": []}]})
    return built


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        return

    def _json(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        log({"kind": "get", "path": self.path})
        path = self.path.split("?")[0]
        if path.endswith("/models"):
            return self._json(200, {"models": [], "data": [], "object": "list"})
        return self._json(404, {"error": {"message": "fake server: not implemented", "type": "not_found"}})

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(size) if size else b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            log({"kind": "bad-json", "path": self.path, "encoding": self.headers.get("Content-Encoding")})
            return self._json(400, {"error": {"message": "fake server: bad json"}})
        path = self.path.split("?")[0]
        if not path.endswith("/responses"):
            log({"kind": "other-post", "path": self.path})
            return self._json(404, {"error": {"message": "fake server: not implemented", "type": "not_found"}})
        items = body.get("input") or []
        if State.dump_path:
            pathlib.Path(State.dump_path).write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
        keyword, step = choose(items)
        built = build_items(step)
        log({"kind": "main", "scenario": keyword, "outputs": outputs(items),
             "tools": [t.get("name") or t.get("type") for t in body.get("tools") or []],
             "reply": [{k: i.get(k) for k in ("type", "name", "arguments", "call_id") if k in i} for i in built]})
        response_id = "resp_" + uuid.uuid4().hex[:16]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def send(data):
            self.wfile.write(f"event: {data['type']}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        send({"type": "response.created", "response": {"id": response_id}})
        for index, item in enumerate(built):
            send({"type": "response.output_item.added", "output_index": index, "item": {**item, "status": "in_progress"}})
            send({"type": "response.output_item.done", "output_index": index, "item": item})
        send({"type": "response.completed", "response": {
            "id": response_id, "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                                         "output_tokens": 5, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 15}}})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--scenarios", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--dump-request", help="write the latest request body here, for protocol inspection")
    args = parser.parse_args()
    State.scenarios = json.loads(pathlib.Path(args.scenarios).read_text(encoding="utf-8"))
    State.log_path = args.log
    State.dump_path = args.dump_request
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("ready", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
