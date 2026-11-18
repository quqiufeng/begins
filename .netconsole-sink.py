import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 6666)); s.settimeout(1.0)
f = open('/x96-build/logs/netconsole.log', 'a', buffering=1)
print("listening 6666", flush=True)
while True:
    try:
        d, a = s.recvfrom(65535)
        f.write(time.strftime('%H:%M:%S') + ' ' + a[0] + ' ' + d.decode('utf-8','replace') + '\n')
    except socket.timeout:
        pass
