#!/usr/bin/env python3
"""Local fake Anthropic Messages API for isolated Claude Code CLI tests.

Only fictional data passes through this server. It never contacts the network.
Scenarios are read from a JSON file: {"<KEYWORD>": [step, step, ...]}. The first
user message containing KEYWORD selects a scenario; the number of assistant
messages already in the request selects the step. Each step is a list of content
blocks, where {"tool_use": name, "input": {...}} becomes a tool_use block.

Every main-loop request is logged to a JSONL file, including every tool_result
the CLI sends back, which is what proves a decision really reached the model.
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
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
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
        if message.get("role") != "user" or not isinstance(message.get("content"), list):
            continue
        for block in message["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                content = block.get("content")
                found.append({
                    "tool_use_id": block.get("tool_use_id"),
                    "is_error": bool(block.get("is_error")),
                    "content": content if isinstance(content, str) else text_of(content),
                })
    return found


def blocks_for(step, keyword):
    blocks = []
    for index, item in enumerate(step):
        if "tool_use" in item:
            blocks.append({
                "type": "tool_use",
                "id": item.get("id") or f"toolu_mock_{uuid.uuid4().hex[:18]}",
                "name": item["tool_use"],
                "input": item["input"],
            })
        else:
            blocks.append({"type": "text", "text": item["text"]})
    return blocks


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

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._json(200, {})

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(size) if size else b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            return self._json(200, {"input_tokens": 10})
        if not path.endswith("/messages"):
            log({"kind": "other", "path": self.path})
            return self._json(200, {})
        has_tools = bool(body.get("tools"))
        keyword, step = choose_step(body) if has_tools else (None, [{"text": "ok"}])
        blocks = blocks_for(step, keyword)
        if has_tools:
            log({"kind": "main", "scenario": keyword, "tool_results": tool_results(body),
                 "reply": [{k: b.get(k) for k in ("type", "id", "name", "input", "text") if k in b} for b in blocks]})
        stop = "tool_use" if any(b["type"] == "tool_use" for b in blocks) else "end_turn"
        message_id = "msg_mock_" + uuid.uuid4().hex[:16]
        if not body.get("stream"):
            return self._json(200, {"id": message_id, "type": "message", "role": "assistant", "model": body.get("model", "mock"),
                                    "content": blocks, "stop_reason": stop, "stop_sequence": None,
                                    "usage": {"input_tokens": 10, "output_tokens": 5}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def send(event, data):
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        send("message_start", {"type": "message_start", "message": {
            "id": message_id, "type": "message", "role": "assistant", "model": body.get("model", "mock"), "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}})
        for index, block in enumerate(blocks):
            if block["type"] == "text":
                send("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
                send("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": block["text"]}})
            else:
                send("content_block_start", {"type": "content_block_start", "index": index, "content_block": {
                    "type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
                send("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {
                    "type": "input_json_delta", "partial_json": json.dumps(block["input"])}})
            send("content_block_stop", {"type": "content_block_stop", "index": index})
        send("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                               "usage": {"output_tokens": 5}})
        send("message_stop", {"type": "message_stop"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--scenarios", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    State.scenarios = json.loads(pathlib.Path(args.scenarios).read_text(encoding="utf-8"))
    State.log_path = args.log
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("ready", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
