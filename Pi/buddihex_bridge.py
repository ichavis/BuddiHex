#!/usr/bin/env python3
"""Serve Hamlib TCP and BuddiHex feedback for one R4 UDP rotator."""
import argparse
import asyncio
import ipaddress
import math
import re
import socket


class Bridge(asyncio.DatagramProtocol):
    def __init__(self, peer):
        self.peer = peer
        self.transport = None
        self.position = None
        self.fault = True
        self.updated = float("-inf")
        self.clients = set()
        self.subscribers = set()

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, address):
        if address != self.peer:
            return
        line = data.decode("utf-8", errors="replace").strip()
        if not line or any(c in line for c in "\r\n"):
            return
        if line.startswith(("GET_BEARING:", "AZ:")):
            parts = line.split(":")
            try:
                value = float(parts[1])
            except ValueError:
                value = math.nan
            self.fault = not 0 <= value <= 360 or any(
                part.lower() in {"stuck", "error!"} for part in parts
            )
            self.position = value % 360 if not self.fault else None
            self.updated = asyncio.get_running_loop().time()
        elif "error" in line.lower() or line.startswith("ERR:"):
            self.fault = True
        for writer in self.subscribers:
            if writer.transport.get_write_buffer_size() > 16384:
                writer.close()
            elif not writer.is_closing():
                writer.write((line + "\n").encode())

    def fresh(self):
        return (not self.fault and self.position is not None
                and asyncio.get_running_loop().time() - self.updated <= 3)

    def send(self, command):
        self.transport.sendto(command.encode(), self.peer)

    async def poll(self):
        while True:
            self.send("GET_BEARING")
            await asyncio.sleep(0.5)

    def buddihex(self, command):
        if command in {"GET_BEARING", "<PST><STOP>"}:
            self.send(command)
            return ""
        target = re.fullmatch(r"<AZIMUTH>([0-9]{1,3})", command)
        if (target and int(target[1]) <= 360) or command == "CAL_DECL":
            if self.fresh():
                self.send(command)
                return ""
            return "ERR: No fresh, fault-free controller position\n"
        return "ERR: Unsupported bridge command\n"

    def hamlib(self, line):
        separator = None
        if line[0] in "+;|,":
            separator = "\n" if line[0] == "+" else line[0]
            line = line[1:]
        fields = line.split()
        if not fields:
            return "RPRT -1\n"
        command, *args = fields
        name = {
            "p": "get_pos", "P": "set_pos", "S": "stop",
            "q": "quit", "Q": "quit",
        }.get(command, command.lstrip("\\"))
        result = 0
        values = []
        if name == "quit":
            return None
        if name == "get_pos" and not args:
            if self.fresh():
                values = [f"{self.position:.6f}", "0.000000"]
            else:
                result = -5
        elif name == "set_pos" and len(args) == 2:
            try:
                azimuth, elevation = map(float, args)
            except ValueError:
                azimuth, elevation = math.nan, math.nan
            if not 0 <= azimuth <= 360 or elevation != 0:
                result = -1
            elif not self.fresh():
                result = -5
            else:
                self.send(f"<AZIMUTH>{math.floor(azimuth + 0.5)}")
        elif name == "stop" and not args:
            self.send("<PST><STOP>")
        else:
            result = -1 if name in {"get_pos", "set_pos", "stop"} else -11
        report = f"RPRT {result}"
        if separator is not None:
            header = " ".join([name + ":", *args])
            if values:
                values = ["Azimuth: " + values[0], "Elevation: " + values[1]]
            return separator.join([header, *values, report]) + "\n"
        return "\n".join(values or [report]) + "\n"

    async def client(self, reader, writer):
        if len(self.clients) >= 16:
            writer.close()
            return
        self.clients.add(writer)
        try:
            while raw := await reader.readline():
                line = raw.decode("ascii").strip()
                if not line:
                    continue
                if line == "BUDDIHEX":
                    self.subscribers.add(writer)
                    reply = "BUDDIHEX 1\n"
                elif writer in self.subscribers:
                    reply = self.buddihex(line)
                else:
                    reply = self.hamlib(line)
                if reply is None:
                    break
                if reply:
                    writer.write(reply.encode())
                    await asyncio.wait_for(writer.drain(), 3)
        except (OSError, ValueError, asyncio.TimeoutError):
            pass
        finally:
            self.clients.discard(writer)
            self.subscribers.discard(writer)
            writer.close()


async def serve(args):
    loop = asyncio.get_running_loop()
    bridge = Bridge((str(args.controller), args.command_port))
    udp, _ = await loop.create_datagram_endpoint(
        lambda: bridge, local_addr=("0.0.0.0", args.reply_port), family=socket.AF_INET
    )
    try:
        server = await asyncio.start_server(
            bridge.client, args.listen, args.port, limit=256, family=socket.AF_INET
        )
        print(f"Listening on {args.listen}:{args.port}, controller {bridge.peer}", flush=True)
        poller = asyncio.create_task(bridge.poll())
        try:
            async with server:
                await server.serve_forever()
        finally:
            poller.cancel()
    finally:
        udp.close()


def port(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return number


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", required=True, type=ipaddress.IPv4Address)
    parser.add_argument("--listen", default="127.0.0.1", type=str)
    parser.add_argument("--port", default=4533, type=port)
    parser.add_argument("--command-port", default=4210, type=port)
    parser.add_argument("--reply-port", default=4211, type=port)
    asyncio.run(serve(parser.parse_args()))
