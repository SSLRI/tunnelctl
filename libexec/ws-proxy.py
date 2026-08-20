#!/usr/bin/env python3

import argparse
import asyncio
import contextlib
import logging
import signal
import sys

SWITCHING = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)

ESTABLISHED = b"HTTP/1.1 200 Connection established\r\n\r\n"

HEADER_LIMIT = 16384
HEADER_TIMEOUT = 4.0
CONNECT_TIMEOUT = 10.0
CHUNK = 65536

log = logging.getLogger("tunnelctl-ws")


def split_endpoint(value, default_port):
    if value.count(":") == 1:
        host, _, port = value.partition(":")
        return host or "0.0.0.0", int(port)
    return value, default_port


async def read_preface(reader):
    buffer = b""
    while b"\r\n\r\n" not in buffer and len(buffer) < HEADER_LIMIT:
        try:
            chunk = await asyncio.wait_for(reader.read(CHUNK), timeout=HEADER_TIMEOUT)
        except asyncio.TimeoutError:
            break
        if not chunk:
            break
        buffer += chunk
    marker = buffer.find(b"\r\n\r\n")
    if marker == -1:
        return buffer, b""
    return buffer[: marker + 4], buffer[marker + 4 :]


async def relay(reader, writer):
    try:
        while True:
            data = await reader.read(CHUNK)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, TimeoutError, OSError):
        pass
    finally:
        with contextlib.suppress(Exception):
            writer.close()


async def serve_client(reader, writer, target_host, target_port):
    peer = writer.get_extra_info("peername")
    header, leftover = await read_preface(reader)

    if header:
        if header.upper().startswith(b"CONNECT"):
            writer.write(ESTABLISHED)
        else:
            writer.write(SWITCHING)
        try:
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            with contextlib.suppress(Exception):
                writer.close()
            return
    else:
        leftover = b""

    try:
        remote_reader, remote_writer = await asyncio.wait_for(
            asyncio.open_connection(target_host, target_port), timeout=CONNECT_TIMEOUT
        )
    except Exception as error:
        log.warning("upstream unavailable for %s: %s", peer, error)
        with contextlib.suppress(Exception):
            writer.close()
        return

    if leftover:
        remote_writer.write(leftover)
        with contextlib.suppress(Exception):
            await remote_writer.drain()

    log.info("session opened from %s", peer)
    await asyncio.gather(
        relay(reader, remote_writer),
        relay(remote_reader, writer),
    )
    log.info("session closed from %s", peer)


async def run(listen_host, listen_port, target_host, target_port, backlog):
    server = await asyncio.start_server(
        lambda r, w: serve_client(r, w, target_host, target_port),
        host=listen_host,
        port=listen_port,
        backlog=backlog,
        reuse_address=True,
    )
    log.info(
        "listening on %s:%s and forwarding to %s:%s",
        listen_host, listen_port, target_host, target_port,
    )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)

    async with server:
        await stop.wait()
    log.info("shutting down")


def main():
    parser = argparse.ArgumentParser(description="WebSocket front end for SSH")
    parser.add_argument("--listen", default="0.0.0.0:80")
    parser.add_argument("--target", default="127.0.0.1:22")
    parser.add_argument("--backlog", type=int, default=512)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.WARNING if args.quiet else logging.INFO,
        format="%(asctime)s  %(levelname)s  %(message)s",
    )

    listen_host, listen_port = split_endpoint(args.listen, 80)
    target_host, target_port = split_endpoint(args.target, 22)

    try:
        asyncio.run(run(listen_host, listen_port, target_host, target_port, args.backlog))
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
