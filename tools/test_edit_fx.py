"""Offline tests: never invoke fx or a provider."""
from contextlib import redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "examples" / "edit-fx.py"
SPEC = importlib.util.spec_from_file_location("edit_fx", SCRIPT)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)
SOURCE = '// 日本語 `comment` *pointer\r\nconst raw = `全文`;\n'
REQUEST = {"prompt": "Rename raw to source", "buffer": {
    "path": "/private/project/secrets/example.go", "content": SOURCE,
    "modified": True, "filetype": "go", "cursor": [2, 0]}}


class EditFxTests(unittest.TestCase):
    def invoke(self, envelope=None, request=None, returncode=0, failure=None, trickle=False):
        if envelope is None:
            envelope = {"output": json.dumps({"message": "変更", "content": SOURCE}, ensure_ascii=False),
                        "final_output": '{"message":"wrong","content":"stripped"}'}
        raw = envelope if isinstance(envelope, bytes) else json.dumps(envelope, ensure_ascii=False).encode()
        process = mock.Mock(pid=123456, returncode=returncode)
        observations = {}

        def spawn(argv, **kwargs):
            observations.update(argv=argv, **kwargs)
            observations["cwd_mode"] = os.stat(kwargs["cwd"]).st_mode & 0o777
            write_fd = os.dup(kwargs["stdout"])

            def communicate(*args, **options):
                try:
                    for start in range(0, len(raw), 16384):
                        pending = memoryview(raw)[start:start + 16384]
                        while pending:
                            pending = pending[os.write(write_fd, pending):]
                    if trickle:
                        held_fd = os.dup(write_fd)

                        def keep_stdout_open():
                            deadline = time.monotonic() + 4
                            try:
                                while time.monotonic() < deadline:
                                    os.write(held_fd, b" ")
                                    time.sleep(0.005)
                            except OSError:
                                pass
                            finally:
                                os.close(held_fd)

                        observations["writer"] = threading.Thread(target=keep_stdout_open, daemon=True)
                        observations["writer"].start()
                    if callable(failure):
                        return failure(*args, **options)
                    if failure:
                        raise failure
                finally:
                    os.close(write_fd)

            process.communicate.side_effect = communicate
            return process

        data = json.dumps(REQUEST if request is None else request, ensure_ascii=False).encode()
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(adapter.subprocess, "Popen", side_effect=spawn) as popen, \
                mock.patch.object(adapter.os, "killpg") as killpg, \
                mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(data), encoding="utf-8")), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            started = time.monotonic()
            status = adapter.main()
            observations["elapsed"] = time.monotonic() - started
            if "writer" in observations:
                observations["writer"].join(timeout=1)
                self.assertFalse(observations["writer"].is_alive())
        self.assertEqual(stderr.getvalue(), "")
        result = json.loads(stdout.getvalue())
        self.assertEqual(stdout.getvalue().count("\n"), 1)
        return status, result, process, popen, killpg, observations

    def test_flags_raw_source_private_cwd_and_raw_output(self):
        status, result, process, popen, _, seen = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(result, {"message": "変更", "content": SOURCE})
        self.assertEqual(seen["argv"], ["fx", "--no-additional-dirs", "ask", "--ask", "--json",
                                        "--no-save", "--system", adapter.SYSTEM])
        self.assertIn("No tools", adapter.SYSTEM)
        self.assertIn("FULL replacement", adapter.SYSTEM)
        self.assertEqual(seen["cwd_mode"], 0o700)
        self.assertFalse(os.path.exists(seen["cwd"]))
        self.assertIs(seen["stderr"], subprocess.DEVNULL)
        self.assertTrue(seen["start_new_session"])
        wire = process.communicate.call_args.args[0]
        self.assertNotIn(b"/private/project", wire)
        self.assertEqual(json.loads(wire), {"prompt": REQUEST["prompt"], "buffer": {
            "name": "example.go", "content": SOURCE, "filetype": "go", "modified": True, "cursor": [2, 0]}})
        self.assertEqual(process.communicate.call_args.kwargs, {"timeout": 115})
        popen.assert_called_once()

    def test_message_only_and_empty_replacement(self):
        for result in ({"message": "No change"}, {"message": "Delete all", "content": ""}):
            with self.subTest(result=result):
                status, actual, *_ = self.invoke({"output": json.dumps(result)})
                self.assertEqual((status, actual), (0, result))

    def test_fail_closed_response(self):
        invalid = [b"not JSON private diagnostic", b"{} trailing", b"[]", {},
                   {"output": None}, {"final_output": '{"message":"fallback forbidden"}'},
                   {"output": '{"message":"unfinished"'},
                   {"output": '```json\n{"message":"fenced"}\n```'},
                   {"output": 'Explanation: {"message":"commentary"}'},
                   {"output": '[]'}, {"output": '{"message":null}'},
                   {"output": '{"message":2}'}, {"output": '{"content":"source"}'},
                   {"output": '{"message":"x","content":null}'},
                   {"output": '{"message":"x","content":false}'},
                   {"output": '{"message":"x","content":"a\\u0000b"}'},
                   {"output": '{"message":"\\ud800"}'},
                   {"output": '{"message":"x","diff":"leak"}'},
                   {"output": '{"message":"x","message":"duplicate"}'},
                   {"output": '{"message":NaN}'},
                   b'x' * (adapter.LIMIT + 1)]
        for envelope in invalid:
            with self.subTest(envelope=repr(envelope)[:100]):
                status, result, *_ = self.invoke(envelope)
                self.assertEqual(status, 1)
                self.assertEqual(result, {"message": "fx edit failed; no changes applied."})

    def test_invalid_input_never_invokes_fx(self):
        requests = [None, [], {}, {"buffer": {}}, copy.deepcopy(REQUEST)]
        requests[-1]["buffer"]["content"] = "x" * adapter.LIMIT
        for field, value in (("path", "relative.go"), ("path", "/private/\x00.go"),
                             ("content", "source\x00"), ("filetype", None),
                             ("modified", 1), ("cursor", [True, 0]), ("cursor", [1])):
            request = copy.deepcopy(REQUEST)
            request["buffer"][field] = value
            requests.append(request)
        request = copy.deepcopy(REQUEST)
        request["prompt"] = "invalid\x00"
        requests.append(request)
        # None is the invoke helper's default, so exercise JSON null separately.
        for request in requests[1:]:
            with self.subTest(request=repr(request)[:100]):
                status, result, _, popen, _, _ = self.invoke(request=request)
                self.assertEqual(status, 1)
                self.assertNotIn("content", result)
                popen.assert_not_called()

    def test_failed_exit_does_not_publish_valid_output(self):
        status, result, *_ = self.invoke(returncode=1)
        self.assertEqual(status, 1)
        self.assertNotIn("content", result)

    def test_timeout_terminates_only_new_child_group(self):
        before = signal.getsignal(signal.SIGTERM)
        status, result, process, _, killpg, _ = self.invoke(
            failure=subprocess.TimeoutExpired("fx", 115))
        self.assertEqual(status, 1)
        self.assertNotIn("content", result)
        self.assertEqual(killpg.call_args_list, [mock.call(process.pid, signal.SIGTERM),
                                                mock.call(process.pid, signal.SIGKILL)])
        self.assertEqual(signal.getsignal(signal.SIGTERM), before)

    def test_sigterm_forwards_to_child_group(self):
        def interrupt(*args, **kwargs):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        status, result, process, _, killpg, _ = self.invoke(failure=interrupt)
        self.assertEqual(status, 1)
        self.assertNotIn("content", result)
        killpg.assert_any_call(process.pid, signal.SIGTERM)
        killpg.assert_any_call(process.pid, signal.SIGKILL)

    def test_stdout_overflow_is_bounded_kills_child_group_and_never_leaks(self):
        captured = bytearray()
        raw = b"PRIVATE_PROVIDER_CREDENTIALS" + b"x" * adapter.LIMIT
        with mock.patch.object(adapter, "bytearray", return_value=captured, create=True):
            status, result, process, _, killpg, _ = self.invoke(raw)
        self.assertEqual(status, 1)
        self.assertEqual(result, {"message": "fx edit failed; no changes applied."})
        self.assertEqual(len(captured), adapter.LIMIT + 1)
        killpg.assert_called_once_with(process.pid, signal.SIGKILL)

    def test_exact_stdout_limit_is_accepted(self):
        envelope = json.dumps({"output": '{"message":"no edit"}'}).encode()
        status, result, *_ = self.invoke(envelope + b" " * (adapter.LIMIT - len(envelope)))
        self.assertEqual((status, result), (0, {"message": "no edit"}))

    def test_trickling_inherited_stdout_cannot_block_cleanup(self):
        # Fake root exits; its descendant ignores the mocked group kill and keeps writing.
        status, result, process, _, killpg, seen = self.invoke(trickle=True)
        self.assertEqual(status, 1)
        self.assertEqual(result, {"message": "fx edit failed; no changes applied."})
        self.assertLess(seen["elapsed"], 3)
        killpg.assert_called_once_with(process.pid, signal.SIGKILL)

    def test_strict_bounded_decode(self):
        for raw in (b"null trailing", b'{"x":1,"x":2}', b"NaN", b"x" * (adapter.LIMIT + 1),
                    b"\xff"):
            with self.subTest(raw=repr(raw)[:50]):
                with self.assertRaises((ValueError, UnicodeError)):
                    adapter.decode(raw)


if __name__ == "__main__":
    unittest.main()
