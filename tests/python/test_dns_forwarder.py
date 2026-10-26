"""DNS framing tests independent of privileged port binding and external networks."""

import socket
import struct
import threading
import unittest
from unittest.mock import Mock

from test_execution import load_module

dns = load_module("dns_forwarder", "dns-forwarder.py")


class DnsTests(unittest.TestCase):
    def test_doh_uses_wireformat_and_verified_tls_name(self):
        query = bytes(range(12))
        answer = query + b"answer"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            received = []

            def server():
                with listener.accept()[0] as conn:
                    stream = conn.makefile("rb")
                    headers = b""
                    size = 0
                    while True:
                        line = stream.readline()
                        headers += line
                        if line.lower().startswith(b"content-length:"):
                            size = int(line.split(b":", 1)[1])
                        if line == b"\r\n":
                            break
                    received.append((headers, stream.read(size)))
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: " +
                                 str(len(answer)).encode() + b"\r\n\r\n" + answer)

            thread = threading.Thread(target=server)
            thread.start()
            context = Mock()
            context.wrap_socket.side_effect = lambda raw, server_hostname: raw
            self.assertEqual(dns.exchange_https("127.0.0.1", query, "resolver.example", context, listener.getsockname()[1]), answer)
            context.wrap_socket.assert_called_once()
            self.assertEqual(context.wrap_socket.call_args.kwargs["server_hostname"], "resolver.example")
            thread.join()
            self.assertIn(b"POST /dns-query HTTP/1.1", received[0][0])
            self.assertIn(b"Host: resolver.example", received[0][0])
            self.assertEqual(received[0][1], query)

    def test_query_and_fragmented_response_are_preserved(self):
        query = bytes(range(12))
        response = query + b"answer"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            received = []

            def server():
                with listener.accept()[0] as conn:
                    size = struct.unpack("!H", dns.receive(conn, 2))[0]
                    received.append(dns.receive(conn, size))
                    for byte in struct.pack("!H", len(response)) + response:
                        conn.sendall(bytes([byte]))

            thread = threading.Thread(target=server)
            thread.start()
            self.assertEqual(dns.exchange("127.0.0.1", query, listener.getsockname()[1]), response)
            thread.join()
            self.assertEqual(received, [query])

    def test_truncated_upstream_frame_is_not_reported_as_a_dns_response(self):
        first, second = socket.socketpair()
        with first, second:
            first.sendall(b"one")
            first.shutdown(socket.SHUT_WR)
            with self.assertRaises(EOFError):
                dns.receive(second, 4)


if __name__ == "__main__":
    unittest.main()
