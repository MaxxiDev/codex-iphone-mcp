#!/usr/bin/env python3
"""Measure relative HID acceleration using Safari mouse events. Python stdlib only.

Run with iphone-use already running. Open the printed URL on the paired iPhone,
then keep the phone and Mac mouse still. This sends movement, never clicks.
Keep the same iOS tracking-speed settings after calibration. Restart iphone-use
after success. Coordinate positioning remains approximate, not pixel-exact.
"""
import argparse
import json
import math
import secrets
import socket
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CALIBRATION_PAGE = b'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>body{margin:0;background:#162233;color:white;font:20px system-ui;overflow:hidden;touch-action:none}p{padding:30px}</style>
<p>Pointer calibration. Keep the phone and Mac mouse still until the terminal finishes.</p>
<script>
const send=v=>fetch(location.pathname,{method:'POST',body:JSON.stringify(v)}).catch(()=>{});
send({type:'loaded',screenWidth:screen.width,screenHeight:screen.height,dpr:devicePixelRatio});
let latest=null;document.addEventListener('mousemove',e=>latest={type:'move',x:e.clientX,y:e.clientY,time:Date.now()});
setInterval(()=>{if(latest){send(latest);latest=null}},50);
</script>'''


class PhoneAPI:
    """The existing local API contract used by the calibration tool."""

    def __init__(self, base_url):
        self.base_url = base_url

    def select_device(self, device_id):
        devices = json.load(urllib.request.urlopen(self.base_url + '/devices', timeout=5))['devices']
        selected = [device for device in devices if device_id is None or device['id'] == device_id]
        if len(selected) != 1 or not selected[0].get('bluetooth'):
            raise RuntimeError('Select exactly one paired phone with --device.')
        return selected[0]

    def nudge(self, device_id, x, y):
        body = json.dumps({'device': device_id, 'dx': x, 'dy': y}).encode()
        urllib.request.urlopen(urllib.request.Request(self.base_url + '/nudge', body), timeout=15).read()


class PointerMeasurements:
    """Shares Safari observations between HTTP threads and the measurement loop."""

    def __init__(self):
        self.lock = threading.Lock()
        self.state = {}
        self.loaded = threading.Event()

    def record(self, value):
        with self.lock:
            if value.get('type') == 'loaded':
                self.state['page'] = value
                self.loaded.set()
            elif value.get('type') == 'move' and value.get('time', 0) > self.state.get('move', {}).get('time', 0):
                self.state['move'] = value

    def wait_for_page(self):
        if not self.loaded.wait(180):
            raise RuntimeError('Timed out waiting for the test page.')
        return self.state['page']

    def position(self, dpr):
        # Let HID notifications and page observations arrive; events can arrive
        # out of order, so the server retains the largest page event timestamp.
        time.sleep(0.6)
        with self.lock:
            value = self.state.get('move')
            if not value:
                raise RuntimeError('Safari did not report pointer movement; calibration cannot continue.')
            return (value['x'] * dpr, value['y'] * dpr)


class CalibrationRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != self.server.token:
            self.send_error(404)
            return
        body = CALIBRATION_PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != self.server.token:
            self.send_error(404)
            return
        try:
            value = json.loads(self.rfile.read(min(4096, int(self.headers.get('Content-Length', 0)))))
            self.server.measurements.record(value)
            self.send_response(204)
            self.end_headers()
        except (ValueError, TypeError):
            self.send_error(400)

    def log_message(self, *_):
        pass


class CalibrationHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, token, measurements):
        self.token = token
        self.measurements = measurements
        super().__init__(address, CalibrationRequestHandler)


class PointerCalibration:
    """Measures the existing single-axis curve, then checks its diagonal model.

    Movement and observation are injected so the full sequence can be checked
    without sending HID input or waiting for a physical phone.
    """

    def __init__(self, device, host, nudge, position):
        self.device = device
        self.host = host
        self.width = device['width']
        self.height = device['height']
        self.nudge = nudge
        self.position = position

    def measure(self):
        self._enter_calibration_area()
        distances = self._measure_horizontal_curve()
        self._verify_vertical_curve(distances)
        profile = dict(host=self.host, screenID=self.device['id'], screenWidth=self.width, screenHeight=self.height,
                       reportInterval=0.03, distances=distances)
        if self._verify_diagonal_curve(distances):
            profile['vectorModel'] = 'radialQuantized'
            print('Diagonal movement verified; combined X/Y tracking enabled.', flush=True)
        else:
            print('Diagonal movement differs; keeping calibrated single-axis tracking.', flush=True)
        return profile

    def _enter_calibration_area(self):
        self.nudge(-1500, -1500)
        # Enter the page from the top-left without clicking browser controls.
        for _ in range(3):
            self.nudge(32, 0)
            self.nudge(0, 32)
        origin = self.position()
        if not 20 < origin[0] < self.width / 2:
            raise RuntimeError('Pointer is outside the calibration area; tracking speed is too high or too low.')

    def _measure_horizontal_curve(self):
        distances = [0.0]
        for count in range(1, 33):
            before = self.position()
            for _ in range(3):
                self.nudge(count, 0)
            after = self.position()
            for _ in range(3):
                self.nudge(-count, 0)
            returned = self.position()
            distance = ((after[0] - before[0]) + (after[0] - returned[0])) / 6
            if (abs(returned[0] - before[0]) > 3 or after[0] >= self.width - 10
                    or not math.isfinite(distance) or distance <= distances[-1]):
                raise RuntimeError('Nonrepeatable movement or screen edge reached; calibration was not saved.')
            distances.append(distance)
            print(f'{count:2}: {distance:.3f} pixels/report', flush=True)
        return distances

    def _verify_vertical_curve(self, distances):
        before = self.position()
        for _ in range(3):
            self.nudge(0, 16)
        after = self.position()
        for _ in range(3):
            self.nudge(0, -16)
        returned = self.position()
        if abs(after[1] - before[1] - distances[16] * 3) > 3 or abs(returned[1] - before[1]) > 3:
            raise RuntimeError('Vertical movement does not match the measured curve; calibration was not saved.')

    def _verify_diagonal_curve(self, distances):
        # A single-axis curve does not establish how the host accelerates a
        # diagonal report. Enable combined X/Y tracking only after measuring it.
        # Check both integral and fractional magnitudes: this host model selects
        # its gain using the integer part of the combined HID vector length.
        radial_verified = True
        for dx, dy in [(12, 16), (16, 12), (7, 7), (16, 16)]:
            before = self.position()
            for _ in range(4):
                self.nudge(dx, dy)
            after = self.position()
            for _ in range(4):
                self.nudge(-dx, -dy)
            returned = self.position()
            magnitude = int(math.hypot(dx, dy))
            predicted = [distances[magnitude] * component / magnitude for component in (dx, dy)]
            for axis in range(2):
                observed = ((after[axis] - before[axis]) + (after[axis] - returned[axis])) / 8
                if abs(observed - predicted[axis]) > 0.6 or abs(returned[axis] - before[axis]) > 3:
                    radial_verified = False
        return radial_verified


def save_profile(directory, host, profile):
    # Write only after all required measurements succeed. Replacement keeps the
    # previous profile available if writing the temporary file fails.
    destination = directory / 'pointer-calibration' / (host.upper() + '.json')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.tmp')
    temporary.write_text(json.dumps(profile, indent=2) + '\n')
    temporary.replace(destination)
    print(f'Saved {destination}\nRestart iphone-use. Keep tracking speed unchanged; positioning is approximate.')


def local_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect(('192.0.2.1', 80))  # choose an interface, send no packet
        return sock.getsockname()[0]


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='device ID from /devices (required for multiple phones)')
    parser.add_argument('--api', default='http://127.0.0.1:7390')
    parser.add_argument('--listen-port', type=int, default=7391)
    parser.add_argument('--address', help='Mac LAN address visible from the iPhone')
    return parser.parse_args()


def main():
    args = parse_arguments()
    api = PhoneAPI(args.api)
    device = api.select_device(args.device)
    directory = Path.home() / 'Library/Application Support/iPhoneUse'
    host = json.loads((directory / 'pairings.json').read_text())[device['id']]
    width, height = device['width'], device['height']
    token = '/' + secrets.token_hex(16)
    measurements = PointerMeasurements()
    address = args.address
    if not address:
        address = local_address()
    server = CalibrationHTTPServer(('0.0.0.0', args.listen_port), token, measurements)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        print(f'Open in iPhone Safari: http://{address}:{args.listen_port}{token}', flush=True)
        page = measurements.wait_for_page()
        dpr = page['dpr']
        if page['screenWidth'] * dpr != width or page['screenHeight'] * dpr != height:
            raise RuntimeError('Safari screen size differs from capture; use portrait and disable page zoom.')
        calibration = PointerCalibration(
            device, host, lambda x, y: api.nudge(device['id'], x, y), lambda: measurements.position(dpr))
        profile = calibration.measure()
        save_profile(directory, host, profile)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
