"""Local board diagnostics over the CH340 while native USB belongs to a phone."""
import argparse
import json
from pathlib import Path
import time
import serial


class BoardUART:
    def __init__(self, port='COM3'):
        self.serial = serial.Serial(port=None, baudrate=115200, timeout=0.2)
        self.serial.dtr = False
        self.serial.rts = False
        self.serial.port = port
        self.serial.open()
        self.request_id = 10

    def close(self):
        self.serial.close()

    def command(self, command, timeout=12, request_id=None):
        self.request_id += 1
        rid = str(request_id if request_id is not None else self.request_id)
        self.serial.reset_input_buffer()
        self.serial.write((rid + ' ' + command + '\n').encode())
        deadline = time.monotonic() + timeout
        collected = bytearray()
        while time.monotonic() < deadline:
            collected.extend(self.serial.read(max(1, self.serial.in_waiting)))
            while b'\n' in collected:
                line, _, collected = collected.partition(b'\n')
                text = line.decode(errors='replace').strip()
                if text.startswith(rid + ' '):
                    return text[len(rid) + 1:]
        raise TimeoutError('No matching UART reply')

    def api(self, path, method='GET', body=None):
        reply = self.command(f'v1 {method} {path}' +
                             (' ' + json.dumps(body, separators=(',', ':')) if body is not None else ''))
        ok, _, value = reply.partition(' ')
        if ok != 'ok':
            raise RuntimeError(reply)
        return json.loads(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', default='COM3')
    parser.add_argument('--save-local-info', type=Path, help='Save token locally without printing it')
    parser.add_argument('command', nargs='?', default='v1 GET status')
    args = parser.parse_args()
    board = BoardUART(args.port)
    try:
        if args.save_local_info:
            info = json.loads(board.command('localinfo', request_id=0))
            args.save_local_info.write_text(json.dumps(info), encoding='utf-8')
            print('Saved local controller credentials; values omitted.')
        else:
            if 'localinfo' in args.command or args.command.startswith('net '):
                parser.error('Use --save-local-info for credentials; network setup belongs in a private script.')
            print(board.command(args.command))
    finally:
        board.close()


if __name__ == '__main__':
    main()
