"""The GPU section of healthcheck.sh against fake sysfs trees.

The rest of the script probes the machine the tests run on; only the lines of the GPU
section are asserted, so the result does not depend on that machine.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "healthcheck.sh"

FAKE_NVIDIA_SMI = """#!/bin/sh
case "$*" in
  -L) i=0; while [ "$i" -lt "${FAKE_GPUS:-1}" ]; do echo "GPU $i: NVIDIA Test (UUID: GPU-$i)"; i=$((i + 1)); done ;;
  *driver_version*) echo 580.95.05 ;;
  *ecc.errors*) echo 0 ;;
esac
"""


class FakeSysfs:
    def __init__(self, root: Path):
        self.root = root
        (root / "bus" / "pci" / "devices").mkdir(parents=True)
        (root / "bus" / "pci" / "drivers").mkdir(parents=True)

    def device(self, slot: str, vendor: str, cls: str, driver: str | None = None, render: bool = False) -> Path:
        d = self.root / "bus" / "pci" / "devices" / slot
        d.mkdir()
        (d / "vendor").write_text(vendor + "\n")
        (d / "class").write_text(cls + "\n")
        if driver:
            target = self.root / "bus" / "pci" / "drivers" / driver
            target.mkdir(exist_ok=True)
            (d / "driver").symlink_to(target)
        if render:
            (d / "drm" / "renderD128").mkdir(parents=True)
        return d


def gpu_lines(sysfs: Path, extra_path: Path | None = None, **env) -> list[str]:
    environ = {**os.environ, "HEALTHCHECK_SYSFS": str(sysfs), **env}
    if extra_path:
        environ["PATH"] = f"{extra_path}:{environ['PATH']}"
    out = subprocess.run(["sh", str(SCRIPT)], capture_output=True, text=True, env=environ, timeout=120).stdout
    section = out.split("=== gpu ===\n", 1)[1].split("=== SUMMARY ===", 1)[0]
    return [line for line in section.splitlines() if line.strip()]


class GpuSectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sys = FakeSysfs(Path(self.tmp.name) / "sys")
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def fake_nvidia_smi(self) -> Path:
        tool = self.bin / "nvidia-smi"
        tool.write_text(FAKE_NVIDIA_SMI)
        tool.chmod(0o755)
        return self.bin

    def test_intel_discrete_card_with_driver_and_render_node(self):
        self.sys.device("0000:03:00.0", "0x8086", "0x030000", driver="i915", render=True)
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="0")
        self.assertIn("PASS  1 Intel discrete GPU(s) on i915, every one with a render node", lines)

    def test_intel_card_without_driver(self):
        self.sys.device("0000:03:00.0", "0x8086", "0x030000")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="0")
        self.assertTrue(any(line.startswith("FAIL  Intel discrete GPU(s) not usable: 0000:03:00.0(no i915/xe driver)") for line in lines), lines)

    def test_intel_card_without_render_node(self):
        self.sys.device("0000:03:00.0", "0x8086", "0x030000", driver="xe")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="0")
        self.assertTrue(any("0000:03:00.0(no render node)" in line for line in lines), lines)

    def test_integrated_graphics_is_not_judged(self):
        self.sys.device("0000:00:02.0", "0x8086", "0x030000")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="0")
        self.assertFalse(any("Intel" in line for line in lines), lines)

    def test_nvidia_card_missing_from_nvidia_smi(self):
        self.sys.device("0000:01:00.0", "0x10de", "0x030000", driver="nvidia")
        self.sys.device("0000:02:00.0", "0x10de", "0x030200", driver="nvidia")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="1")
        self.assertIn("FAIL  GPU count mismatch: PCI bus=2, nvidia-smi=1 (a card fell off the bus or is not driven)", lines)

    def test_nvidia_cards_all_seen(self):
        self.sys.device("0000:01:00.0", "0x10de", "0x030000", driver="nvidia")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="1")
        self.assertIn("PASS  nvidia-smi sees 1 GPU(s), driver 580.95.05", lines)

    @unittest.skipIf(shutil.which("nvidia-smi"), "this machine has a real nvidia-smi")
    def test_nvidia_card_without_tools_names_the_kernel_driver(self):
        self.sys.device("0000:01:00.0", "0x10de", "0x030000")
        lines = gpu_lines(self.sys.root)
        self.assertIn(
            "FAIL  1 NVIDIA GPU(s) on the PCI bus but no nvidia-smi, kernel driver: none (needs the gpu-server-setup skill)",
            lines,
        )

    def test_fatal_aer_on_a_gpu(self):
        d = self.sys.device("0000:03:00.0", "0x8086", "0x030000", driver="i915", render=True)
        (d / "aer_dev_fatal").write_text("TOTAL_ERR_FATAL 1\n")
        (d / "aer_dev_nonfatal").write_text("TOTAL_ERR_NONFATAL 0\n")
        (d / "aer_dev_correctable").write_text("TOTAL_ERR_COR 0\n")
        lines = gpu_lines(self.sys.root, self.fake_nvidia_smi(), FAKE_GPUS="0")
        self.assertIn("FAIL  PCIe 0000:03:00.0: fatal=1 nonfatal=0 (uncorrected link errors)", lines)


class SyntaxTests(unittest.TestCase):
    def test_posix_sh_parses_it(self):
        self.assertEqual(subprocess.run(["sh", "-n", str(SCRIPT)]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
