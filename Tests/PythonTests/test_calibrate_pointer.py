"""Calibration contract tests using simulated movement and no physical device."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'calibrate-pointer.py'
SPEC = importlib.util.spec_from_file_location('calibrate_pointer', SCRIPT)
calibration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(calibration)


class SimulatedPointer:
    def __init__(self, diagonal_scale=1, vertical_scale=1, return_drift=0):
        self.x = 400
        self.y = 400
        self.diagonal_scale = diagonal_scale
        self.vertical_scale = vertical_scale
        self.return_drift = return_drift
        self.events = []

    def nudge(self, dx, dy):
        self.events.append(('nudge', dx, dy))
        scale = self.diagonal_scale if dx and dy else 1
        self.x = max(0, self.x + dx * scale)
        self.y = max(0, self.y + dy * scale * self.vertical_scale)
        if dx < 0 and not dy:
            self.x += self.return_drift

    def position(self):
        self.events.append(('position',))
        return self.x, self.y


class PointerCalibrationTests(unittest.TestCase):
    device = {'id': 'phone-1', 'width': 750, 'height': 1334}

    def measure(self, pointer):
        runner = calibration.PointerCalibration(self.device, 'aa:bb:cc', pointer.nudge, pointer.position)
        with contextlib.redirect_stdout(io.StringIO()):
            return runner.measure()

    def test_full_measurement_sequence_and_profile(self):
        pointer = SimulatedPointer()
        profile = self.measure(pointer)
        self.assertEqual(profile, {
            'host': 'aa:bb:cc', 'screenID': 'phone-1', 'screenWidth': 750, 'screenHeight': 1334,
            'reportInterval': 0.03, 'distances': [float(count) for count in range(33)],
            'vectorModel': 'radialQuantized',
        })
        # The observed sampling boundaries are part of the calibration protocol:
        # every forward/reverse burst is measured before the next burst starts.
        expected = [('nudge', -1500, -1500)]
        expected += [('nudge', 32, 0), ('nudge', 0, 32)] * 3
        expected += [('position',)]
        for count in range(1, 33):
            expected += [('position',)] + [('nudge', count, 0)] * 3
            expected += [('position',)] + [('nudge', -count, 0)] * 3 + [('position',)]
        expected += [('position',)] + [('nudge', 0, 16)] * 3
        expected += [('position',)] + [('nudge', 0, -16)] * 3 + [('position',)]
        for dx, dy in [(12, 16), (16, 12), (7, 7), (16, 16)]:
            expected += [('position',)] + [('nudge', dx, dy)] * 4
            expected += [('position',)] + [('nudge', -dx, -dy)] * 4 + [('position',)]
        self.assertEqual(pointer.events, expected)

    def test_diagonal_mismatch_retains_valid_single_axis_profile(self):
        pointer = SimulatedPointer(diagonal_scale=2)
        profile = self.measure(pointer)
        self.assertNotIn('vectorModel', profile)
        self.assertEqual(profile['distances'], [float(count) for count in range(33)])
        # Verification must run all four diagonal cases even after a mismatch.
        self.assertEqual(pointer.events[-5:], [('nudge', -16, -16)] * 4 + [('position',)])

    def test_horizontal_return_drift_rejects_measurement(self):
        with self.assertRaisesRegex(RuntimeError, 'Nonrepeatable movement or screen edge reached'):
            self.measure(SimulatedPointer(return_drift=2))

    def test_vertical_mismatch_rejects_measurement(self):
        with self.assertRaisesRegex(RuntimeError, 'Vertical movement does not match the measured curve'):
            self.measure(SimulatedPointer(vertical_scale=2))

    def test_origin_outside_calibration_area_stops_before_curve_measurement(self):
        pointer = SimulatedPointer()
        pointer.position = Mock(return_value=(20, 96))
        with self.assertRaisesRegex(RuntimeError, 'Pointer is outside the calibration area'):
            self.measure(pointer)
        pointer.position.assert_called_once_with()
        self.assertEqual(len(pointer.events), 7)


class PointerMeasurementsTests(unittest.TestCase):
    def test_latest_timestamp_wins_and_position_preserves_observation_delay(self):
        measurements = calibration.PointerMeasurements()
        page = {'type': 'loaded', 'dpr': 2}
        measurements.record(page)
        self.assertIs(measurements.wait_for_page(), page)
        measurements.record({'type': 'move', 'x': 10, 'y': 20, 'time': 100})
        measurements.record({'type': 'move', 'x': 99, 'y': 99, 'time': 99})
        measurements.record({'type': 'move', 'x': 50, 'y': 50, 'time': 100})
        with patch.object(calibration.time, 'sleep') as sleep:
            self.assertEqual(measurements.position(2), (20, 40))
        sleep.assert_called_once_with(0.6)

    def test_missing_movement_and_page_timeout_keep_existing_errors(self):
        measurements = calibration.PointerMeasurements()
        with patch.object(calibration.time, 'sleep'), self.assertRaisesRegex(
                RuntimeError, 'Safari did not report pointer movement; calibration cannot continue.'):
            measurements.position(2)
        measurements.loaded = Mock()
        measurements.loaded.wait.return_value = False
        with self.assertRaisesRegex(RuntimeError, 'Timed out waiting for the test page.'):
            measurements.wait_for_page()
        measurements.loaded.wait.assert_called_once_with(180)


class CalibrationIOTests(unittest.TestCase):
    def test_api_selection_and_nudge_keep_urls_payload_and_timeouts(self):
        api = calibration.PhoneAPI('http://127.0.0.1:7390')
        devices = {'devices': [
            {'id': 'other', 'bluetooth': True}, {'id': 'selected', 'bluetooth': True},
        ]}
        with patch.object(calibration.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(devices).encode())) as request:
            self.assertEqual(api.select_device('selected'), devices['devices'][1])
            request.assert_called_once_with('http://127.0.0.1:7390/devices', timeout=5)
        response = Mock()
        with patch.object(calibration.urllib.request, 'urlopen', return_value=response) as request:
            api.nudge('selected', 12, -16)
            sent = request.call_args.args[0]
            self.assertEqual(sent.full_url, 'http://127.0.0.1:7390/nudge')
            self.assertEqual(sent.data, b'{"device": "selected", "dx": 12, "dy": -16}')
            self.assertEqual(request.call_args.kwargs, {'timeout': 15})
            response.read.assert_called_once_with()

    def test_save_replaces_host_profile_with_existing_json_format(self):
        profile = {'host': 'aa:bb', 'distances': [0.0, 1.0], 'reportInterval': 0.03}
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            calibration.save_profile(Path(directory), 'aa:bb', profile)
            destination = Path(directory) / 'pointer-calibration' / 'AA:BB.json'
            self.assertEqual(destination.read_text(), json.dumps(profile, indent=2) + '\n')
            self.assertFalse(destination.with_suffix('.tmp').exists())


if __name__ == '__main__':
    unittest.main()
