#!/usr/bin/env python3
"""Local fake OpenAI-compatible Chat Completions API for isolated Kimi Code CLI tests.

Only fictional data passes through this server. It never contacts the network.
Scenarios are read from a JSON file: {"<KEYWORD>": [step, step, ...]}. The first user
message containing KEYWORD selects a scenario; the number of assistant messages already
in the request selects the step. A step is a list of items, either {"text": "..."} or
{"tool": "Bash", "args": {...}, "id": "optional"}.

Every chat request is logged to a JSONL file, including every role=tool message the CLI
sends back, which is what proves a decision really reached the model.
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


def log(record):
    record = {"t": round(time.time(), 3), **record}
    with State.lock, open(State.log_path, "a", encoding="utf-8") as out:
        out.write(json.dumps(record, ensure_ascii=False) + "\n")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def choose_step(body):
    messages = body.get("messages") or []
    joined = "\n".join(text_of(m.get("content")) for m in messages if m.get("role") == "user")
    for keyword, steps in State.scenarios.items():
        if keyword in joined:
            done = sum(1 for m in messages if m.get("role") == "assistant")
            return keyword, steps[done] if done < len(steps) else [{"text": "SCENARIO_COMPLETE"}]
    return None, [{"text": "ok"}]


def tool_results(body):
    found = []
    for message in body.get("messages") or []:
        if message.get("role") == "tool":
            found.append({"tool_call_id": message.get("tool_call_id"), "content": text_of(message.get("content"))})
    return found


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
        log({"kind": "other", "method": "GET", "path": self.path})
        if self.path.split("?")[0].endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": "mock-model", "object": "model"}]})
        self._json(200, {})

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(size) if size else b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        path = self.path.split("?")[0]
        if not path.endswith("/chat/completions"):
            log({"kind": "other", "method": "POST", "path": self.path})
            return self._json(404, {"error": {"message": "not found"}})
        has_tools = bool(body.get("tools"))
        keyword, step = choose_step(body) if has_tools else (None, [{"text": "ok"}])
        calls = [i for i in step if "tool" in i]
        text = "".join(i.get("text", "") for i in step if "text" in i)
        call_list = [{"index": n, "id": c.get("id") or f"call_mock_{uuid.uuid4().hex[:16]}", "type": "function",
                      "function": {"name": c["tool"], "arguments": json.dumps(c["args"])}} for n, c in enumerate(calls)]
        log({"kind": "main" if has_tools else "aux", "scenario": keyword, "tool_results": tool_results(body),
             "n_messages": len(body.get("messages") or []), "tools": [t.get("function", {}).get("name") for t in body.get("tools") or []],
             "reply_text": text, "reply_calls": [{"id": c["id"], "name": c["function"]["name"], "args": c["function"]["arguments"]} for c in call_list]})
        finish = "tool_calls" if call_list else "stop"
        chat_id = "chatcmpl-mock" + uuid.uuid4().hex[:12]
        created = int(time.time())
        model = body.get("model", "mock-model")
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        if not body.get("stream"):
            message = {"role": "assistant", "content": text or None}
            if call_list:
                message["tool_calls"] = [{k: v for k, v in c.items() if k != "index"} for c in call_list]
            return self._json(200, {"id": chat_id, "object": "chat.completion", "created": created, "model": model,
                                    "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def send(delta, finish_reason=None, extra=None):
            chunk = {"id": chat_id, "object": "chat.completion.chunk", "created": created, "model": model,
                     "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}
            chunk.update(extra or {})
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()

        send({"role": "assistant", "content": ""})
        if text:
            send({"content": text})
        if call_list:
            send({"tool_calls": call_list})
        send({}, finish)
        send({}, finish, {"usage": usage, "choices": []})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--scenarios", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    State.scenarios = json.loads(pathlib.Path(args.scenarios).read_text(encoding="utf-8"))
    State.log_path = args.log
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("ready", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
