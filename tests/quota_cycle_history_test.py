import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class QuotaCycleHistoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.runner = pathlib.Path(cls.temp.name) / 'runner'
        subprocess.run(['swiftc', str(ROOT / 'Sources/QuotaCycleHistory.swift'), str(ROOT / 'tests/fixtures/quota-cycle-history/main.swift'), '-o', str(cls.runner)], check=True, cwd=ROOT)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_case(self, name):
        subprocess.run([str(self.runner), name], check=True, cwd=ROOT)

    def test_first_observation(self):
        self.run_case('firstObservation')

    def test_same_window(self):
        self.run_case('sameWindow')
