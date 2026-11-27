#!/usr/bin/env python3
# 极简 CDP 客户端：TCP 直连 9222 的 devtools ws，Runtime.evaluate 一句话
import base64, json, os, socket, struct, sys, urllib.request

def page_ws():
    lst = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list", timeout=3))
    for it in lst:
        if it.get("type") == "page":
            return it["webSocketDebuggerUrl"], it.get("url"), it.get("title")
    raise SystemExit("no page")

def connect(url):
    host, port = "127.0.0.1", 9222
    path = url.split("9222", 1)[1]
    s = socket.create_connection((host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % (path, host, port, key)
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    assert b"101" in buf.split(b"\r\n")[0], buf[:200]
    return s, buf.split(b"\r\n\r\n", 1)[1]

def send(s, text):
    data = text.encode()
    mask = os.urandom(4)
    hdr = b"\x81"
    n = len(data)
    if n < 126:
        hdr += bytes([0x80 | n])
    elif n < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        hdr += bytes([0x80 | 127]) + struct.pack("!Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    s.sendall(hdr + mask + masked)

def recv_exact(s, n, pre=b""):
    buf = pre
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("closed")
        buf += chunk
    return buf[:n], buf[n:]

def recv_msg(s, pre=b""):
    while True:
        h, rest = recv_exact(s, 2, pre)
        b1, b2 = h[0], h[1]
        n = b2 & 0x7F
        if n == 126:
            ext, rest = recv_exact(s, 2, rest)
            n = struct.unpack("!H", ext)[0]
        elif n == 127:
            ext, rest = recv_exact(s, 8, rest)
            n = struct.unpack("!Q", ext)[0]
        mask = b""
        if b2 & 0x80:
            mask, rest = recv_exact(s, 4, rest)
        payload, rest = recv_exact(s, n, rest)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        op = b1 & 0x0F
        if op == 1:
            return payload.decode("utf-8", "replace"), rest
        if op == 8:
            raise SystemExit("ws closed by peer")

def main(expr, method=None, params=None):
    url, u, t = page_ws()
    sys.stderr.write("page %s | %s\n" % (t, u))
    s, rest = connect(url)
    if method:
        send(s, json.dumps({"id": 1, "method": method, "params": params or {}}))
    else:
        send(s, json.dumps({"id": 1, "method": "Runtime.evaluate",
                            "params": {"expression": expr, "returnByValue": True, "awaitPromise": True}}))
    while True:
        msg, rest = recv_msg(s, rest)
        d = json.loads(msg)
        if d.get("id") == 1:
            r = d.get("result", {})
            if "exceptionDetails" in r:
                print("EXCEPTION:", json.dumps(r["exceptionDetails"])[:800])
            else:
                v = r.get("result", {})
                print(v.get("value") if "value" in v else json.dumps(v)[:800])
            return

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--nav":
        main(None, "Page.navigate", {"url": sys.argv[2]})
    else:
        main(sys.argv[1] if len(sys.argv) > 1 else "1+1")
