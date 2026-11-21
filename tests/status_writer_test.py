import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class StatusWriterTest(unittest.TestCase):
    def test_coalescing_retry_and_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = pathlib.Path(temporary) / "status-writer"
            subprocess.run(["swiftc", str(ROOT / "Sources/RefreshScheduling.swift"),
                            str(ROOT / "tests/fixtures/status-writer/main.swift"),
                            "-o", str(runner)], check=True)
            subprocess.run([str(runner)], check=True, timeout=12)
