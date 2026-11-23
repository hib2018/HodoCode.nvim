"""Offline tests for SDK translation validation, batching, and resumable CLI."""
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("translate_stdlib.py").resolve()
SPEC = importlib.util.spec_from_file_location("translate_stdlib", SCRIPT)
translator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(translator)


def document(text):
    return {
        "id": hashlib.sha256(text.encode()).hexdigest(),
        "text": text,
        "references": ["pkg.Function", "pkg.Other", "pkg.Third", "pkg.Fourth"],
    }


class ValidationTests(unittest.TestCase):
    def test_japanese_and_exact_ids(self):
        docs = [document("Function returns a value.")]
        key = docs[0]["id"]
        translator.validate({key: "関数は値を返します。"}, docs)
        translator.validate({}, [])
        for invalid in (None, [], {}, {key: "日本語", "extra": "日本語"},
                        {"wrong": "日本語"}, {key: None}, {key: 1},
                        {key: ""}, {key: " \n"}, {key: "English only"},
                        {key: "日本語\x00"}):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    translator.validate(invalid, docs)

    def test_markers_must_be_preserved(self):
        doc = document("Returns a *File and `*File`.")
        translated = "日本語の *File と `*File` を返します。"
        translator.validate({doc["id"]: translated}, [doc])
        for invalid in (translated.replace("*", ""),
                        translated.replace("`", ""),
                        translated + "*", translated + "`"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    translator.validate({doc["id"]: invalid}, [doc])

    def test_truncation_boundary(self):
        doc = document("a" * 1000)
        with self.assertRaises(ValueError):
            translator.validate({doc["id"]: "日" * 149}, [doc])
        translator.validate({doc["id"]: "日" * 150}, [doc])
        short = document("a" * 400)
        translator.validate({short["id"]: "日"}, [short])


class LiteralTests(unittest.TestCase):
    def test_round_trip_and_collision(self):
        for text in ("plain text", "Returns a *File and `*File`.",
                     "HODOCODE_LITERAL_STAR_0__ * ` HODOCODE_LITERAL_X *"):
            with self.subTest(text=text):
                protected, replacements = translator.protect_literals(text)
                self.assertNotIn("*", protected)
                self.assertNotIn("`", protected)
                self.assertEqual(len(replacements), text.count("*") + text.count("`"))
                for token, marker in replacements.items():
                    self.assertNotIn(token, text)
                    self.assertEqual(protected.count(token), 1)
                    self.assertIn(marker, ("*", "`"))
                self.assertEqual(translator.restore_literals(protected, replacements), text)

    def test_rejects_missing_duplicated_and_changed_tokens(self):
        protected, replacements = translator.protect_literals("*File `code`")
        for token in replacements:
            for invalid in (protected.replace(token, ""), protected + token,
                            protected.replace(token, token.lower())):
                with self.subTest(invalid=invalid):
                    with self.assertRaises(ValueError):
                        translator.restore_literals(invalid, replacements)
        for invalid in (None, 1, {}):
            with self.assertRaises(ValueError):
                translator.restore_literals(invalid, replacements)


class BatchingTests(unittest.TestCase):
    def test_character_and_item_limits(self):
        docs = [document(str(index) * 3) for index in range(5)]
        for max_chars, max_items, sizes in ((6, 10, [2, 2, 1]),
                                            (100, 2, [2, 2, 1]),
                                            (5, 2, [1, 1, 1, 1, 1])):
            with self.subTest(max_chars=max_chars, max_items=max_items):
                batches = list(translator.batches(docs, max_chars, max_items))
                self.assertEqual([len(batch) for batch in batches], sizes)
                self.assertEqual([doc for batch in batches for doc in batch], docs)
                for batch in batches:
                    self.assertLessEqual(len(batch), max_items)
                    self.assertLessEqual(sum(len(doc["text"]) for doc in batch), max_chars)

    def test_empty_and_oversized_document(self):
        self.assertEqual(list(translator.batches([], 5, 2)), [])
        docs = [document("too long"), document("ok")]
        self.assertEqual(list(translator.batches(docs, 5, 2)), [[docs[0]], [docs[1]]])


class CLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source.json"
        self.output = self.root / "catalog.json"
        self.calls = self.root / "calls.jsonl"
        self.fx = self.root / "fake-fx"
        self.fx.write_text(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            "payload = json.load(sys.stdin)\n"
            "items = payload['items']\n"
            "assert [item['id'] for item in items] == [str(i) for i in range(len(items))]\n"
            "assert all(len(item['references']) <= 3 for item in items)\n"
            f"with open({str(self.calls)!r}, 'a') as log:\n"
            "    log.write(json.dumps(payload) + '\\n')\n"
            "translations = {item['id']: '日本語の翻訳です。' for item in items}\n"
            "print(json.dumps({'output': json.dumps({'translations': translations})}))\n",
            encoding="utf-8",
        )
        self.fx.chmod(0o755)
        self.docs = [document(f"Function {index} returns a value.\n") for index in range(3)]
        self.write_source()

    def write_source(self):
        self.source.write_text(json.dumps({"go_version": "go-test", "documents": self.docs}))

    def run_cli(self, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.source), str(self.output),
             "--fx", str(self.fx), "--workers", "1", "--batch-items", "2", *extra],
            cwd=self.root, capture_output=True, text=True, timeout=20,
        )

    def call_payloads(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_translation_partial_resume_and_cached_resume(self):
        first = self.run_cli("--limit-batches", "1")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(len(json.loads(self.output.read_text())["translations"]), 2)
        self.assertEqual(len(self.call_payloads()), 1)

        resumed = self.run_cli()
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        catalog = json.loads(self.output.read_text())
        self.assertEqual(catalog["go_version"], "go-test")
        self.assertEqual(catalog["translations"], {
            doc["id"]: "日本語の翻訳です。" for doc in self.docs
        })
        payloads = self.call_payloads()
        self.assertEqual([len(payload["items"]) for payload in payloads], [2, 1])
        self.assertEqual(
            [item["text"] for payload in payloads for item in payload["items"]],
            [doc["text"] for doc in self.docs],
        )
        before = self.output.read_bytes()
        cached = self.run_cli()
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        self.assertEqual(self.call_payloads(), payloads)
        self.assertEqual(self.output.read_bytes(), before)

    def test_raw_output_preserves_markers_over_final_output(self):
        self.docs = [document("Returns a *File and `*File`.")]
        self.write_source()
        translated = "日本語の *File と `*File` を返します。"
        fake = self.fx.read_text().replace(
            "'日本語の翻訳です。'",
            "item['text'].replace('Returns a ', '日本語の ').replace(' and ', ' と ').replace('.', ' を返します。')",
        )
        fake = fake.replace(
            "print(json.dumps({'output': json.dumps({'translations': translations})}))",
            "raw = json.dumps({'translations': translations})\n"
            "print(json.dumps({'output': raw, 'final_output': raw.replace('HODOCODE_LITERAL', 'STRIPPED')}))",
        )
        self.fx.write_text(fake, encoding="utf-8")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        catalog = json.loads(self.output.read_text())
        self.assertEqual(catalog["translations"], {self.docs[0]["id"]: translated})
        self.assertEqual(len(self.call_payloads()), 1)
        item = self.call_payloads()[0]["items"][0]
        self.assertNotIn("*", item["text"])
        self.assertNotIn("`", item["text"])
        self.assertIn("HODOCODE_LITERAL_STAR", item["text"])
        self.assertIn("HODOCODE_LITERAL_BACKTICK", item["text"])
        self.assertEqual(item["references"], self.docs[0]["references"][:3])

    def test_missing_raw_output_fails_without_caching(self):
        self.fx.write_text(
            self.fx.read_text().replace("{'output':", "{'final_output':"),
            encoding="utf-8",
        )
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.call_payloads()), 1)
        self.assertFalse(self.output.exists())

    def test_commented_raw_output_fails_despite_valid_final_output(self):
        self.fx.write_text(
            self.fx.read_text().replace(
                "print(json.dumps({'output': json.dumps({'translations': translations})}))",
                "raw = json.dumps({'translations': translations})\n"
                "print(json.dumps({'output': 'Here is the translation:\\n' + raw, 'final_output': raw}))",
            ),
            encoding="utf-8",
        )
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.call_payloads()), 1)
        self.assertFalse(self.output.exists())

    def test_check_rejects_stale_marker_loss_without_ai(self):
        self.docs = [document("Returns a *File and `*File`.")]
        self.write_source()
        original = json.dumps({
            "go_version": "go-test",
            "translations": {self.docs[0]["id"]: "日本語の File と File を返します。"},
        })
        self.output.write_text(original)
        result = self.run_cli("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.output.read_text(), original)

    def test_check_incomplete_without_ai(self):
        original = json.dumps({
            "go_version": "go-test",
            "translations": {self.docs[0]["id"]: "日本語の翻訳です。"},
        })
        self.output.write_text(original)
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("1/3", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.output.read_text(), original)

    def test_check_complete_without_ai(self):
        original = json.dumps({
            "go_version": "go-test",
            "translations": {doc["id"]: "日本語の翻訳です。" for doc in self.docs},
        })
        self.output.write_text(original)
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("3/3", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.output.read_text(), original)

    def test_timeout_skips_queued_jobs_and_preserves_catalog(self):
        self.docs.append(document("Fourth function returns a value.\n"))
        self.write_source()
        original = json.dumps({
            "go_version": "go-test",
            "translations": {self.docs[0]["id"]: "日本語の翻訳です。"},
        }).encode()
        self.output.write_bytes(original)
        private = "PRIVATE_PROVIDER_DIAGNOSTIC"
        timeout = subprocess.TimeoutExpired(
            cmd=[str(self.fx), private], timeout=300,
            output=private, stderr=private,
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        argv = [str(SCRIPT), str(self.source), str(self.output),
                "--fx", str(self.fx), "--workers", "1", "--batch-items", "1"]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(translator.subprocess, "run", side_effect=timeout) as run, \
                redirect_stdout(stdout), redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                translator.main()
        # Python maps a SystemExit diagnostic string to process exit status 1.
        status = raised.exception.code
        self.assertEqual(status if isinstance(status, int) else 1, 1)
        run.assert_called_once()
        self.assertEqual(run.call_args.kwargs["timeout"], 300)
        self.assertEqual(run.call_args.args[0][0], str(self.fx))
        self.assertIn("timed out", stdout.getvalue())
        self.assertNotIn(private, stdout.getvalue() + stderr.getvalue() + str(status))
        self.assertEqual(self.output.read_bytes(), original)
        self.assertFalse(self.calls.exists())

    def test_first_failure_skips_queued_jobs(self):
        self.docs.append(document("Fourth function returns a value.\n"))
        self.write_source()
        self.fx.write_text(
            self.fx.read_text().replace(
                "translations = {", "sys.exit(7)\ntranslations = {", 1
            ),
            encoding="utf-8",
        )
        result = self.run_cli("--batch-items", "1")
        self.assertNotEqual(result.returncode, 0)
        payloads = self.call_payloads()
        self.assertEqual(len(payloads), 1)
        self.assertEqual(len(payloads[0]["items"]), 1)
        self.assertEqual(payloads[0]["items"][0]["text"], self.docs[0]["text"])
        self.assertFalse(self.output.exists())

    def test_hash_mismatch_rejected_before_ai(self):
        self.docs[-1]["text"] = "Tampered documentation."
        self.write_source()
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.output.exists())

    def test_version_mismatch_rejected_before_ai(self):
        original = json.dumps({"go_version": "another-go", "translations": {}})
        self.output.write_text(original)
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.output.read_text(), original)


if __name__ == "__main__":
    unittest.main()
