"""Credential-free local origins for the Docker network test. Never connects to the Internet."""

import http.server
import os
from pathlib import Path
import select
import socket
import socketserver
import struct
import threading


def receive(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def relay(first, second):
    while True:
        readable, _, _ = select.select([first, second], [], [], 10)
        if not readable:
            return
        for source in readable:
            data = source.recv(65536)
            if not data:
                return
            (second if source is first else first).sendall(data)


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(10)
        if Path("/tmp/no-proxy").exists():
            return
        try:
            if self.server.server_address[1] in (1080, 1082):
                version, count = receive(conn, 2)
                methods = receive(conn, count)
                assert version == 5
                if self.server.server_address[1] == 1082 or Path("/tmp/require-auth").exists():
                    assert 2 in methods
                    conn.sendall(b"\x05\x02")
                    assert receive(conn, 1) == b"\x01"
                    user = receive(conn, receive(conn, 1)[0])
                    password = receive(conn, receive(conn, 1)[0])
                    expected = ((b"executor-fixture", b"executor-password") if self.server.server_address[1] == 1082
                                else (b"fixture-user", b"fixture-password"))
                    assert (user, password) == expected
                    conn.sendall(b"\x01\x00")
                else:
                    assert 0 in methods
                    conn.sendall(b"\x05\x00")
                version, command, _, kind = receive(conn, 4)
                assert version == 5 and command == 1
                if kind == 1:
                    receive(conn, 4)
                elif kind == 3:
                    receive(conn, receive(conn, 1)[0])
                else:
                    receive(conn, 16)
                port = struct.unpack("!H", receive(conn, 2))[0]
                conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            else:
                headers = b""
                while not headers.endswith(b"\r\n\r\n") and len(headers) < 8192:
                    headers += receive(conn, 1)
                method, target, _ = headers.split(b"\r\n", 1)[0].split()
                assert method == b"CONNECT"
                port = int(target.rsplit(b":", 1)[1])
                conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            # Deliberately ignore the requested IP: all TCP is served by this local fixture.
            with socket.create_connection(("127.0.0.1", 8053 if port == 53 else 8080), timeout=5) as upstream:
                relay(conn, upstream)
        except (OSError, EOFError, ValueError, AssertionError):
            pass


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"proxied" if self.client_address[0] == "127.0.0.1" else b"direct"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def dns_response(query):
    position = 12
    labels = []
    while query[position]:
        size = query[position]
        labels.append(query[position + 1:position + size + 1])
        position += size + 1
    position += 1
    qtype = struct.unpack("!H", query[position:position + 2])[0]
    question = query[12:position + 4]
    count = 1 if qtype == 1 else 0
    result = query[:2] + struct.pack("!HHHHH", 0x8180, 1, count, 0, 0) + question
    if count:
        address = os.environ["TEST_LAN_ADDRESS"] if b".".join(labels) == b"internal.example" else "198.51.100.10"
        result += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(address)
    return result


class DnsTcp(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(10)
            size = struct.unpack("!H", receive(self.request, 2))[0]
            response = dns_response(receive(self.request, size))
            self.request.sendall(struct.pack("!H", len(response)) + response)
        except (OSError, EOFError, IndexError):
            pass


class DnsUdp(socketserver.BaseRequestHandler):
    def handle(self):
        query, sock = self.request
        sock.sendto(dns_response(query), self.client_address)


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request[1].sendto(self.request[0], self.client_address)


class TcpServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


servers = [TcpServer(("0.0.0.0", port), handler) for port, handler in
           ((1080, Proxy), (1081, Proxy), (1082, Proxy), (8053, DnsTcp))]
servers += [http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Origin),
            socketserver.ThreadingUDPServer(("0.0.0.0", 8053), DnsUdp),
            socketserver.ThreadingUDPServer(("0.0.0.0", 8090), Echo)]
for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
