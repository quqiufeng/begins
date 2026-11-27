#!/usr/bin/env python3
# 极简 benchmark 服务：静态页 + /log?p=&fps= 落盘（支持 Range，方便顺手测视频）
import sys, os, json, re
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(ROOT, 'fps.log')

class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith('/log?'):
            q = dict(re.findall(r'([^?&=]+)=([^&]*)', self.path.split('?', 1)[1]))
            with open(LOG, 'a') as fh:
                fh.write(json.dumps(q) + "\n")
            self.send_response(204); self.end_headers(); return
        if self.path.startswith('/reset'):
            open(LOG, 'w').close()
            self.send_response(204); self.end_headers(); return
        # Range 支持（视频排查用）
        path = self.translate_path(self.path)
        if os.path.isfile(path) and 'Range' in self.headers:
            size = os.path.getsize(path)
            m = re.match(r'bytes=(\d*)-(\d*)', self.headers['Range'])
            s = int(m.group(1) or 0); e = int(m.group(2) or size - 1)
            e = min(e, size - 1)
            self.send_response(206)
            self.send_header('Content-Type', self.guess_type(path))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (s, e, size))
            self.send_header('Content-Length', str(e - s + 1))
            self.end_headers()
            with open(path, 'rb') as fh:
                fh.seek(s); self.wfile.write(fh.read(e - s + 1))
            return
        super().do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(('0.0.0.0', port), H).serve_forever()
