#!/usr/bin/env python3
"""Send a single explicit test event to the local IslandReplica TCP listener."""
import argparse
import json
import socket
import sys


def port_number(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError('port must be an integer') from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError('port must be between 1 and 65535')
    return port


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=port_number, required=True, help='local listener port')
    parser.add_argument('--session-id', required=True)
    parser.add_argument('--event', required=True)
    parser.add_argument('--agent')
    parser.add_argument('--title')
    parser.add_argument('--detail')
    args = parser.parse_args()
    if not args.session_id.strip() or not args.event.strip():
        parser.error('session-id and event must not be blank')
    payload = {'sessionId': args.session_id, 'event': args.event}
    for key in ('agent', 'title', 'detail'):
        value = getattr(args, key)
        if value is not None:
            payload[key] = value
    data = (json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')
    if len(data) - 1 > 65_536:
        parser.error('event exceeds the 65536-byte per-line limit')
    try:
        with socket.create_connection(('127.0.0.1', args.port), timeout=2) as conn:
            conn.sendall(data)
    except OSError as exc:
        print(f'Unable to send event to local listener: {exc}', file=sys.stderr)
        return 1
    print('Event sent to local TCP listener (receipt by the app is not confirmed).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
