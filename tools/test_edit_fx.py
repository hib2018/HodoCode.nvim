"""Offline tests: never invoke fx or a provider."""
from contextlib import redirect_stderr, redirect_stdout
import copy
import hashlib
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
EDITS = [{"old_text": "const raw", "new_text": "const source"}]
VERSION = hashlib.sha256(SOURCE.encode()).hexdigest()


class EditFxTests(unittest.TestCase):
    def invoke(self, envelope=None, request=None, returncode=0, failure=None,
               trickle=False, env=None, spawn_failure=None, heartbeat=False, wait_timeout=False):
        if envelope is None:
            envelope = {"output": json.dumps({"message": "変更", "edits": EDITS}, ensure_ascii=False),
                        "final_output": '{"message":"wrong","content":"stripped"}'}
        raw = envelope if isinstance(envelope, bytes) else json.dumps(envelope, ensure_ascii=False).encode()
        process = mock.Mock(pid=123456, returncode=returncode)
        if wait_timeout:
            process.wait.side_effect = [subprocess.TimeoutExpired("PRIVATE", 1), None]
        observations = {}

        def spawn(argv, **kwargs):
            if spawn_failure:
                raise spawn_failure
            observations.update(argv=argv, **kwargs)
            observations["cwd_mode"] = os.stat(kwargs["cwd"]).st_mode & 0o777
            write_fd = os.dup(kwargs["stdout"])
            calls = 0

            def communicate(*args, **options):
                nonlocal calls
                calls += 1
                if heartbeat and calls == 1:
                    time.sleep(options["timeout"])
                    raise subprocess.TimeoutExpired("fx", options["timeout"])
                if failure:
                    if callable(failure):
                        return failure(*args, **options)
                    raise failure
                try:
                    for start in range(0, len(raw), 16384):
                        pending = memoryview(raw)[start:start + 16384]
                        while pending:
                            pending = pending[os.write(write_fd, pending):]
                    if trickle:
                        held_fd = os.dup(write_fd)

                        def keep_stdout_open():
                            deadline = time.monotonic() + 2
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
                finally:
                    os.close(write_fd)
                    observations["closed"] = True

            observations["write_fd"] = write_fd
            process.communicate.side_effect = communicate
            return process

        data = json.dumps(REQUEST if request is None else request, ensure_ascii=False).encode()
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"HODOCODE_AGENT_TIMEOUT_MS": "120000", "HODOCODE_EDIT_PROTOCOL": "2", **(env or {})}), \
                mock.patch.object(adapter.subprocess, "Popen", side_effect=spawn) as popen, \
                mock.patch.object(adapter.os, "killpg") as killpg, \
                mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(data), encoding="utf-8")), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            started = time.monotonic()
            status = adapter.main()
            observations["elapsed"] = time.monotonic() - started
            if "write_fd" in observations and not observations.get("closed"):
                os.close(observations["write_fd"])
            if "writer" in observations:
                observations["writer"].join(timeout=1)
                self.assertFalse(observations["writer"].is_alive())
        self.assertEqual(stderr.getvalue(), "")
        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        observations["events"] = events
        for event in events[:-1]:
            self.assertEqual(set(event), {"event", "phase", "elapsed_ms"})
            self.assertEqual(event["event"], "status")
            self.assertIn(event["phase"], ("starting", "waiting", "received", "validating"))
            self.assertIs(type(event["elapsed_ms"]), int)
            self.assertGreaterEqual(event["elapsed_ms"], 0)
        if (env or {}).get("HODOCODE_EDIT_PROTOCOL", "2") == "2":
            self.assertEqual(events[0]["phase"], "starting")
        else:
            self.assertEqual(len(events), 1)
        return status, events[-1], process, popen, killpg, observations

    def assert_error(self, status, result, code=None):
        self.assertEqual(status, 1)
        self.assertEqual(set(result), {"event", "code", "elapsed_ms"})
        self.assertEqual(result["event"], "error")
        self.assertIn(result["code"], ("timeout", "authentication", "rate_limit", "transport",
                                      "provider_exit", "invalid_json", "invalid_response",
                                      "size_limit", "spawn_failed", "cancelled"))
        if code:
            self.assertEqual(result["code"], code)

    def test_flags_raw_source_private_cwd_and_raw_output(self):
        status, result, process, popen, _, seen = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(result, {"event": "result", "version": VERSION, "message": "変更", "edits": EDITS})
        self.assertEqual(seen["argv"], ["fx", "--no-additional-dirs", "ask", "--ask", "--json",
                                        "--no-save", "--system", adapter.SYSTEM])
        self.assertIn("No tools", adapter.SYSTEM)
        self.assertIn("ORIGINAL", adapter.SYSTEM)
        self.assertEqual(seen["cwd_mode"], 0o700)
        self.assertFalse(os.path.exists(seen["cwd"]))
        self.assertIs(seen["stderr"], subprocess.DEVNULL)
        self.assertTrue(seen["start_new_session"])
        wire = process.communicate.call_args.args[0]
        self.assertNotIn(b"/private/project", wire)
        self.assertEqual(json.loads(wire), {"prompt": REQUEST["prompt"], "buffer": {
            "name": "example.go", "content": SOURCE, "filetype": "go", "modified": True, "cursor": [2, 0]}})
        self.assertLessEqual(process.communicate.call_args.kwargs["timeout"], 1)
        self.assertEqual([e.get("phase") for e in seen["events"][:-1]], ["starting", "received", "validating"])
        popen.assert_called_once()

    def test_shared_conversation_and_current_buffer_reach_provider(self):
        request = copy.deepcopy(REQUEST)
        request.update(session_id="session-a", request_id="session-a-2", intent="edit", history=[
            {"role": "user", "content": "なぜ？", "intent": "chat", "file": "/private/old/example.go",
             "request_id": "session-a-1", "status": "sent"},
            {"role": "assistant", "content": "以前の回答", "status": "nochange"}])
        status, _, process, *_ = self.invoke(request=request)
        self.assertEqual(status, 0)
        wire = json.loads(process.communicate.call_args.args[0])
        self.assertEqual(wire["session_id"], "session-a")
        self.assertEqual(wire["request_id"], "session-a-2")
        self.assertEqual(wire["intent"], "edit")
        self.assertEqual(wire["history"][0]["file"], "example.go")
        self.assertEqual(wire["history"][1]["content"], "以前の回答")
        self.assertEqual(wire["buffer"]["content"], SOURCE)
        self.assertNotIn("/private/", json.dumps(wire))

    def test_question_uses_readonly_system_and_rejects_edits(self):
        request = copy.deepcopy(REQUEST)
        request.update(session_id="s", request_id="s-1", intent="chat", history=[])
        status, result, _, _, _, seen = self.invoke(
            {"output": json.dumps({"message": "回答"})}, request=request)
        self.assertEqual(status, 0)
        self.assertEqual(seen["argv"][-1], adapter.CHAT_SYSTEM)
        self.assertEqual(result["message"], "回答")
        self.assertEqual(result["edits"], [])
        for change in ({"content": ""}, {"content": SOURCE}, {"edits": EDITS}):
            status, result, *_ = self.invoke(
                {"output": json.dumps({"message": "bad", **change})}, request=request)
            self.assert_error(status, result, "invalid_response")

    def test_invalid_conversation_does_not_start_provider(self):
        for extra in ({"intent": "execute"}, {"request_id": False}, {"request_id": ""},
                      {"history": {}}, {"history": [{"role": "system", "content": "bad"}]},
                      {"history": [{"role": "user", "content": False}]},
                      {"history": [{"role": "assistant", "content": "x", "edits": [{}]}]}):
            status, result, _, popen, *_ = self.invoke(request={**REQUEST, **extra})
            self.assert_error(status, result, "invalid_response")
            popen.assert_not_called()

    def test_older_client_without_protocol_negotiation(self):
        for response in ({"message": "raw", "content": SOURCE}, {"message": "unchanged"}):
            status, result, _, _, _, seen = self.invoke(
                {"output": json.dumps(response), "final_output": "stripped"},
                env={"HODOCODE_EDIT_PROTOCOL": ""})
            self.assertEqual((status, result), (0, response))
            self.assertEqual(seen["argv"][-1], adapter.LEGACY_SYSTEM)
            self.assertEqual(len(seen["events"]), 1)
        status, result, *_ = self.invoke(returncode=1, env={"HODOCODE_EDIT_PROTOCOL": ""})
        self.assertEqual((status, result), (1, {"message": "fx edit failed; no changes applied."}))

    def test_message_only_and_legacy_raw_replacement(self):
        for response in ({"message": "No change"}, {"message": "Delete all", "content": ""},
                         {"message": "raw", "content": SOURCE}):
            with self.subTest(response=response):
                status, actual, *_ = self.invoke({"output": json.dumps(response), "final_output": "wrong"})
                expected = dict(response)
                if "content" not in expected:
                    expected["edits"] = []
                self.assertEqual((status, actual), (0, {"event": "result", "version": VERSION, **expected}))

    def test_original_unique_nonoverlapping_edits(self):
        for edits in ([{"old_text": "const raw", "new_text": "const source"},
                       {"old_text": "const source", "new_text": "second"}],
                      [{"old_text": "const raw", "new_text": ""}, {"old_text": "raw", "new_text": "x"}],
                      [{"old_text": "`", "new_text": "x"}],
                      [{"old_text": "", "new_text": "x"}],
                      [{"old_text": "absent", "new_text": "x"}],
                      [{"old_text": "const raw", "new_text": 2}],
                      [{"old_text": "raw", "new_text": "x", "extra": 1}], None):
            with self.subTest(edits=edits):
                status, result, *_ = self.invoke({"output": json.dumps({"message": "x", "edits": edits})})
                self.assert_error(status, result, "invalid_response")
        edits = [{"old_text": "raw", "new_text": "source"}, {"old_text": "全文", "new_text": "`*"}]
        status, result, *_ = self.invoke({"output": json.dumps({"message": "ok", "edits": edits})})
        self.assertEqual(status, 0)
        self.assertEqual(result["edits"], edits)

    def test_patch_boundaries_and_empty_original_insertion(self):
        request = copy.deepcopy(REQUEST)
        request["buffer"]["content"] = ""
        insertion = [{"old_text": "", "new_text": "`日本語` *pointer\n"}]
        status, result, *_ = self.invoke(
            {"output": json.dumps({"message": "insert", "edits": insertion})}, request=request)
        self.assertEqual(status, 0)
        self.assertEqual(result["edits"], insertion)
        self.assertEqual(result["version"], hashlib.sha256(b"").hexdigest())
        adjacent = [{"old_text": "a", "new_text": "b"}, {"old_text": "b", "new_text": "a"}]
        self.assertEqual(adapter.validate({"message": "ok", "edits": adjacent}, "ab")["edits"], adjacent)
        with self.assertRaises(ValueError):
            adapter.validate({"message": "overlap", "edits": [{"old_text": "aa", "new_text": "b"}]}, "aaa")
        edits = [{"old_text": "[%03d]" % n, "new_text": "x"} for n in range(257)]
        source = "".join(change["old_text"] for change in edits)
        self.assertEqual(len(adapter.validate({"message": "ok", "edits": edits[:256]}, source)["edits"]), 256)
        with self.assertRaises(ValueError):
            adapter.validate({"message": "too many", "edits": edits}, source)

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
                   {"output": '{"message":"x","edits":[],"content":"x"}'},
                   {"output": '{"message":"x","message":"duplicate"}'},
                   {"output": '{"message":NaN}'},
                   b'x' * (adapter.LIMIT + 1)]
        for envelope in invalid:
            with self.subTest(envelope=repr(envelope)[:100]):
                status, result, *_ = self.invoke(envelope)
                self.assert_error(status, result)

    def test_invalid_input_never_invokes_fx(self):
        requests = [[], {}, {"buffer": {}}, copy.deepcopy(REQUEST)]
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
        for request in requests:
            with self.subTest(request=repr(request)[:100]):
                status, result, _, popen, _, _ = self.invoke(request=request)
                self.assert_error(status, result)
                popen.assert_not_called()

    def test_failed_exit_does_not_guess_cause_or_publish_output(self):
        status, result, *_ = self.invoke(returncode=1)
        self.assert_error(status, result, "provider_exit")

    def test_timeout_uses_configured_budget_and_cleans_child_group(self):
        before = signal.getsignal(signal.SIGTERM)
        def timeout(*args, **options):
            time.sleep(options["timeout"])
            raise subprocess.TimeoutExpired("fx PRIVATE", options["timeout"])
        status, result, process, _, killpg, seen = self.invoke(
            failure=timeout, env={"HODOCODE_AGENT_TIMEOUT_MS": "500"}, wait_timeout=True)
        self.assert_error(status, result, "timeout")
        self.assertLessEqual(process.communicate.call_args.kwargs["timeout"], 0.5)
        self.assertLess(seen["elapsed"], 2)
        killpg.assert_any_call(process.pid, signal.SIGTERM)
        killpg.assert_any_call(process.pid, signal.SIGKILL)
        self.assertEqual(signal.getsignal(signal.SIGTERM), before)

    def test_real_elapsed_heartbeat_retries_same_child_without_input(self):
        status, result, process, popen, _, seen = self.invoke(heartbeat=True)
        self.assertEqual(status, 0)
        popen.assert_called_once()
        self.assertEqual(process.communicate.call_count, 2)
        self.assertEqual(process.communicate.call_args_list[1].args, ())
        waiting = [e for e in seen["events"] if e.get("phase") == "waiting"]
        self.assertEqual(len(waiting), 1)
        self.assertGreaterEqual(waiting[0]["elapsed_ms"], 900)
        self.assertLess(waiting[0]["elapsed_ms"], 2500)

    def test_sigterm_and_sigint_cancel_child_group(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            before = signal.getsignal(sig)
            def interrupt(*args, **kwargs):
                signal.getsignal(sig)(sig, None)
            status, result, process, _, killpg, _ = self.invoke(failure=interrupt)
            self.assert_error(status, result, "cancelled")
            killpg.assert_any_call(process.pid, signal.SIGTERM)
            killpg.assert_any_call(process.pid, signal.SIGKILL)
            self.assertEqual(signal.getsignal(sig), before)

    def test_spawn_failure_and_invalid_timeout_are_safe(self):
        status, result, *_ = self.invoke(spawn_failure=OSError("PRIVATE PROVIDER PATH"))
        self.assert_error(status, result, "spawn_failed")
        for value in ("NaN", "0", "-1", "1.5"):
            status, result, _, popen, *_ = self.invoke(env={"HODOCODE_AGENT_TIMEOUT_MS": value})
            self.assert_error(status, result, "invalid_response")
            popen.assert_not_called()

    def test_stdout_overflow_is_bounded_kills_child_group_and_never_leaks(self):
        captured = bytearray()
        raw = b"PRIVATE_PROVIDER_CREDENTIALS" + b"x" * adapter.LIMIT
        with mock.patch.object(adapter, "bytearray", return_value=captured, create=True):
            status, result, process, _, killpg, _ = self.invoke(raw)
        self.assert_error(status, result, "size_limit")
        self.assertEqual(len(captured), adapter.LIMIT + 1)
        killpg.assert_any_call(process.pid, signal.SIGKILL)

    def test_exact_stdout_limit_is_accepted(self):
        envelope = json.dumps({"output": '{"message":"no edit"}'}).encode()
        status, result, *_ = self.invoke(envelope + b" " * (adapter.LIMIT - len(envelope)))
        self.assertEqual(status, 0)
        self.assertEqual(result["edits"], [])

    def test_trickling_inherited_stdout_cannot_block_cleanup(self):
        status, result, process, _, killpg, seen = self.invoke(trickle=True)
        self.assert_error(status, result, "provider_exit")
        self.assertLess(seen["elapsed"], 1)
        killpg.assert_any_call(process.pid, signal.SIGKILL)

    def test_status_events_flush(self):
        output = mock.Mock()
        with mock.patch.dict(os.environ, {"HODOCODE_EDIT_PROTOCOL": "2"}), \
                mock.patch.object(sys, "stdout", output), \
                mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(b"{}"))):
            self.assertEqual(adapter.main(), 1)
        self.assertEqual(output.flush.call_count, 2)

    def test_strict_bounded_decode(self):
        for raw in (b"null trailing", b'{"x":1,"x":2}', b"NaN", b"x" * (adapter.LIMIT + 1), b"\xff"):
            with self.subTest(raw=repr(raw)[:50]):
                with self.assertRaises(adapter.AdapterError):
                    adapter.decode(raw)


if __name__ == "__main__":
    unittest.main()
