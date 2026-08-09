#!/usr/bin/env python3
"""MLX 本地法官服务 — iPhone 通过局域网调用 Mac 端的 MLX LLM。

启动: python3 scripts/mlx_judge_server.py
调用: curl -X POST http://MACHOST:8766/judge -d '{"prompt": "..."}'
"""

import json, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 8766

class JudgeHandler(BaseHTTPRequestHandler):
    model = None
    tokenizer = None

    @classmethod
    def load_model(cls):
        if cls.model is None:
            from mlx_lm import load
            print("[MLXJudge] Loading Qwen2.5-0.5B-Instruct-4bit...")
            cls.model, cls.tokenizer = load("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
            print("[MLXJudge] Ready.")
        return cls.model, cls.tokenizer

    def do_POST(self):
        if self.path != '/judge':
            self.send_error(404); return
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        prompt = body.get('prompt', '')
        if not prompt:
            self.send_error(400, "missing prompt"); return

        try:
            model, tokenizer = self.load_model()
            messages = [{"role": "user", "content": prompt}]
            input_ids = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
            output = model.generate(input_ids, max_tokens=500, temp=0.1)
            response = tokenizer.decode(output[0][len(input_ids[0]):], skip_special_tokens=True)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'text': response}, ensure_ascii=False).encode())
        except Exception as e:
            self.send_error(500, str(e))

    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

print(f'[MLXJudge] Server: http://localhost:{PORT}')
HTTPServer(('127.0.0.1', PORT), JudgeHandler).serve_forever()
