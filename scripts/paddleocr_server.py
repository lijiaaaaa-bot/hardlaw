#!/usr/bin/env python3
"""PaddleOCR 本地 HTTP 服务 — iPhone 通过网络调用 Mac 端 PaddleOCR"""
import json, base64, os
from http.server import HTTPServer, BaseHTTPRequestHandler
from paddleocr import PaddleOCR

PORT = 8765

class OCRHandler(BaseHTTPRequestHandler):
    ocr = None

    def do_POST(self):
        if self.path != '/ocr':
            self.send_error(404); return
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        img_data = base64.b64decode(body['image'])
        img_path = '/tmp/paddleocr_temp.png'
        with open(img_path, 'wb') as f: f.write(img_data)
        try:
            if OCRHandler.ocr is None: OCRHandler.ocr = PaddleOCR(lang='ch')
            result = OCRHandler.ocr.predict(img_path)
            texts = result[0].get('rec_texts', [])
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'texts': texts, 'full_text': '\n'.join(texts), 'line_count': len(texts)
            }, ensure_ascii=False).encode())
        except Exception as e:
            self.send_error(500, str(e))
        finally:
            if os.path.exists(img_path): os.unlink(img_path)

    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

print(f'PaddleOCR 服务: http://localhost:{PORT}')
HTTPServer(('127.0.0.1', PORT), OCRHandler).serve_forever()
