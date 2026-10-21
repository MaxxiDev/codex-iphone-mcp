"""Fresh MCP connections, protocol failures, screenshots, and no action replay."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "codex/skills/iphone-use/scripts/mcp_call.py"
spec = importlib.util.spec_from_file_location("mcp_call", SCRIPT)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)

SERVER = '''
import base64, json, sys, time
mode, log = sys.argv[1:]
for line in sys.stdin:
    message = json.loads(line)
    with open(log, "a") as output:
        output.write(json.dumps(message) + "\\n")
    if "id" not in message:
        if mode == "stall_write":
            time.sleep(3)
        continue
    if mode == "close_init":
        sys.exit(0)
    if message["method"] == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}
    else:
        if mode == "close_action":
            sys.exit(0)
        if mode == "timeout":
            time.sleep(3)
        if mode == "stderr":
            sys.stderr.write("diagnostic" * 20000)
            sys.stderr.flush()
        if mode == "invalid_json":
            print("not JSON", flush=True)
            continue
        content = [
            {"type": "image", "data": base64.b64encode(b"test image").decode(), "mimeType": "image/jpeg"},
            {"type": "text", "text": "Screenshot of phone-1, 600x1200 px."},
        ]
        if mode == "invalid_image":
            content[0]["data"] = "not base64!"
        result = {"content": content}
        if mode == "tool_error":
            result = {"isError": True, "content": [{"type": "text", "text": "Screenshot unavailable after action"}]}
        print(json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {}}), flush=True)
    number = message["id"] if mode != "wrong_id" else 999
    print(json.dumps({"jsonrpc": "2.0", "id": number, "result": result}), flush=True)
'''


class ReconnectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="iphone use reconnect ")
        self.directory = Path(self.temp.name)
        self.server = self.directory / "mock_server.py"
        self.server.write_text(SERVER)
        self.log = self.directory / "requests.jsonl"

    def tearDown(self):
        self.temp.cleanup()

    def call(self, mode="ok", tool="screenshot", timeout=2):
        return client.call([sys.executable, "-B", str(self.server), mode, str(self.log)], tool,
                           {"device": "phone-1"}, self.directory, timeout=timeout)

    def test_handshake_then_one_call_and_absolute_screenshot_file(self):
        result = self.call()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["content"][1]["text"], "Screenshot of phone-1, 600x1200 px.")
        path = Path(result["content"][0]["path"])
        self.assertTrue(path.is_absolute())
        self.assertEqual(path.read_bytes(), b"test image")
        messages = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([message["method"] for message in messages],
                         ["initialize", "notifications/initialized", "tools/call"])
        self.assertEqual(messages[-1]["params"], {"name": "screenshot", "arguments": {"device": "phone-1"}})

    def test_transport_closed_after_action_is_never_replayed(self):
        result = self.call("close_action", "tap")
        self.assertFalse(result["ok"])
        self.assertTrue(result["may_have_executed"])
        self.assertIn("transport closed", result["error"])
        messages = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(sum(message["method"] == "tools/call" for message in messages), 1)

    def test_transport_closed_before_initialize_never_sends_action(self):
        result = self.call("close_init", "tap")
        self.assertFalse(result["may_have_executed"])
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_protocol_and_image_failures_are_reported(self):
        for mode, expected in (("wrong_id", "response ID"), ("invalid_json", "invalid JSON"),
                               ("invalid_image", "encoding")):
            with self.subTest(mode=mode):
                result = self.call(mode)
                self.assertFalse(result["ok"])
                self.assertIn(expected, result["error"])
                self.assertFalse(result["may_have_executed"])

    def test_tool_error_after_action_does_not_claim_action_failed_to_execute(self):
        result = self.call("tool_error", "tap")
        self.assertFalse(result["ok"])
        self.assertTrue(result["may_have_executed"])

    def test_timeout_stops_only_its_process_without_replaying(self):
        result = self.call("timeout", "tap", timeout=0.2)
        self.assertFalse(result["ok"])
        self.assertIn("Timed out", result["error"])
        self.assertTrue(result["may_have_executed"])

    def test_stderr_cannot_block_the_protocol(self):
        self.assertTrue(self.call("stderr")["ok"])

    def test_stalled_input_pipe_has_a_bounded_timeout(self):
        result = client.call([sys.executable, "-B", str(self.server), "stall_write", str(self.log)],
                             "type_text", {"text": "x" * 2_000_000}, timeout=0.2)
        self.assertFalse(result["ok"])
        self.assertIn("Timed out sending", result["error"])
        self.assertTrue(result["may_have_executed"])

    def test_parallel_connections_have_unique_screenshots_and_independent_failures(self):
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(self.call, ["ok", "close_init", "ok"]))
        self.assertEqual([result["ok"] for result in results], [True, False, True])
        paths = [result["content"][0]["path"] for result in results if result["ok"]]
        self.assertEqual(len(set(paths)), 2)
        self.assertTrue(all(Path(path).read_bytes() == b"test image" for path in paths))

    def test_invalid_arguments_do_not_launch_server(self):
        for arguments in ("[]", '{"x":NaN}', "not JSON"):
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "tap", "--arguments", arguments],
                                    capture_output=True, text=True, timeout=5, cwd="/")
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stdout)["may_have_executed"])


if __name__ == "__main__":
    unittest.main()
