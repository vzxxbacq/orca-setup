#!/usr/bin/env python3
"""Forward loopback DNS over TCP; the namespace firewall sends upstream TCP through the proxy."""

import concurrent.futures
import http.client
import socket
import ssl
import struct
import sys
import threading


def receive(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("incomplete DNS frame")
        data.extend(chunk)
    return bytes(data)


def exchange(address, query, port=53):
    with socket.create_connection((address, port), timeout=8) as upstream:
        upstream.sendall(struct.pack("!H", len(query)) + query)
        size = struct.unpack("!H", receive(upstream, 2))[0]
        return receive(upstream, size)


def exchange_https(address, query, tls_name, context=None, port=443):
    context = context or ssl.create_default_context()
    with socket.create_connection((address, port), timeout=8) as raw:
        with context.wrap_socket(raw, server_hostname=tls_name) as tls:
            headers = (f"POST /dns-query HTTP/1.1\r\nHost: {tls_name}\r\n"
                       f"Content-Type: application/dns-message\r\nAccept: application/dns-message\r\n"
                       f"Content-Length: {len(query)}\r\nConnection: close\r\n\r\n").encode("ascii")
            tls.sendall(headers + query)
            response = http.client.HTTPResponse(tls)
            response.begin()
            if response.status != 200 or response.getheader("Content-Type", "").split(";", 1)[0] != "application/dns-message":
                raise OSError("DNS-over-HTTPS response rejected")
            body = response.read(65536)
            if not 12 <= len(body) <= 65535:
                raise OSError("DNS-over-HTTPS message length rejected")
            return body


def serve(address, transport="tcp", tls_name="cloudflare-dns.com"):
    if transport not in ("tcp", "https"):
        raise ValueError("unsupported DNS transport")
    context = ssl.create_default_context() if transport == "https" else None

    def forward(query):
        return exchange_https(address, query, tls_name, context) if transport == "https" else exchange(address, query)

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind(("127.0.0.1", 53))
    tcp.bind(("127.0.0.1", 53))
    tcp.listen(64)
    # Bound pending work as well as active threads. Excess queries time out and clients can retry.
    slots = threading.BoundedSemaphore(64)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=32)

    def answer_udp(query, peer):
        try:
            udp.sendto(forward(query), peer)
        except (OSError, EOFError, struct.error, http.client.HTTPException):
            pass
        finally:
            slots.release()

    def answer_tcp(conn):
        try:
            with conn:
                conn.settimeout(8)
                while True:
                    size = struct.unpack("!H", receive(conn, 2))[0]
                    response = forward(receive(conn, size))
                    conn.sendall(struct.pack("!H", len(response)) + response)
        except (OSError, EOFError, struct.error, http.client.HTTPException):
            pass
        finally:
            slots.release()

    def accept_tcp():
        while True:
            conn, _ = tcp.accept()
            if slots.acquire(blocking=False):
                pool.submit(answer_tcp, conn)
            else:
                conn.close()

    threading.Thread(target=accept_tcp, daemon=True).start()
    while True:
        query, peer = udp.recvfrom(65535)
        if len(query) >= 12 and slots.acquire(blocking=False):
            pool.submit(answer_udp, query, peer)


if __name__ == "__main__":
    serve(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "tcp", sys.argv[3] if len(sys.argv) > 3 else "cloudflare-dns.com")
