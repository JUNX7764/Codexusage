import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class UIRefinementsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.runner = pathlib.Path(cls.temp.name) / 'ui-refinements-runner'
        sources = [ROOT / 'Sources' / name for name in
                   ('PanelVisuals.swift', 'DeltaChip.swift', 'AnimatedTokenValue.swift', 'PanelCustomization.swift')]
        # 按宿主架构选 target：arm64 / x86_64 均可本机编译运行（universal 双架构约定）。
        subprocess.run(['swiftc', '-target', f'{platform.machine()}-apple-macos13.0', *map(str, sources),
                        str(ROOT / 'tests/fixtures/ui-refinements/main.swift'), '-o', str(cls.runner)],
                       check=True, cwd=ROOT)

    def run_case(self, name):
        subprocess.run([str(self.runner), name], check=True, cwd=ROOT)

    def test_daily_corners(self):
        self.run_case('dailyCorners')

    def test_capacity_track(self):
        self.run_case('capacityTrack')

    def test_delta_chip(self):
        self.run_case('deltaChip')

    def test_token_transition(self):
        self.run_case('tokenTransition')

    def test_layout_model(self):
        self.run_case('layoutModel')

if __name__ == '__main__':
    unittest.main()
