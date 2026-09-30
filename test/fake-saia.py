#!/usr/bin/env python3
"""Fake SAIA OpenAI-compatible endpoint for the mini-swe-agent smoke test.

Serves /v1/models (listing the models the installer registers) and
/v1/chat/completions (a canned reply). Prints the bound port on stdout.

  REPLY   the canned assistant reply (default OK-FAKE)
"""
import http.server, json, os, sys

REPLY = os.environ.get("REPLY", "OK-FAKE")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("fake-saia: " + fmt % a + "\n")

    def send(self, code, body, ctype="application/json"):
        body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self.send(200, json.dumps({"object": "list", "data": [
                {"id": "fake-model", "object": "model", "owned_by": "fake"}]}))
        else:
            self.send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.send(404, json.dumps({"error": "not found"}))
        self.send(200, json.dumps({
            "id": "chatcmpl-fake", "object": "chat.completion", "created": 0,
            "model": "fake-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY},
                         "finish_reason": "stop"}],
        }))


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
