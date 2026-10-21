"""Real process-death recovery tests; the Debug helper uses a file-backed system settings."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


HELPER = Path(os.environ.get("GAMEMODE_RECOVERY_HELPER", "build/DerivedData/Build/Products/Debug/GameMode.app/Contents/MacOS/GameModeRecovery")).resolve()


@unittest.skipUnless(HELPER.is_file(), "Build the Debug recovery helper first")
class RecoveryProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gamemode-recovery-")
        self.root = Path(self.temporary.name)
        self.keyboard = self.root / "keyboard.json"
        self.write_keyboard(False, False)
        self.processes = []
        self.environment = dict(os.environ, LLVM_PROFILE_FILE=str(self.root / "coverage-%p.profraw"))

    def tearDown(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
        self.temporary.cleanup()

    def write_keyboard(self, live, normal, boot="test-boot"):
        data = {"live": live, "preferences": {"global": normal, "isManaged": False}, "bootSession": boot}
        temporary = self.keyboard.with_suffix(".new")
        temporary.write_text(json.dumps(data))
        temporary.replace(self.keyboard)

    def spawn(self, *arguments, executable=HELPER):
        process = subprocess.Popen([str(executable), "--fixture-root", str(self.root), *arguments], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.environment)
        self.processes.append(process)
        return process

    def wait_for(self, condition, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.05)
        self.fail("Timed out waiting for independent recovery")

    def armed_owner(self):
        self.spawn("--watch")
        owner = self.spawn("--fixture-owner")
        self.wait_for(lambda: (self.root / "armed").exists())
        self.assertTrue(json.loads(self.keyboard.read_text())["live"])
        return owner

    def clean(self):
        manifest = self.root / "GameMode/manifest.json"
        return manifest.exists() and json.loads(manifest.read_text())["phase"] == "clean"

    def test_sigkill_restores_without_reopening_owner(self):
        owner = self.armed_owner()
        time.sleep(0.7)
        self.assertFalse(self.clean(), "Helper must not restore a live owner's session")
        owner.kill()
        owner.wait(timeout=5)
        self.wait_for(self.clean)
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])

    def test_sigkill_restores_every_persistent_subsystem(self):
        system = self.root / "system.json"
        original = {"mouse": 0.3, "gesture": 2, "power": {"b": 1, "c": 0}, "refreshRate": 60}
        system.write_text(json.dumps(original))
        owner = self.armed_owner()
        self.assertEqual(json.loads(system.read_text())["mouse"], 1.5)
        self.assertEqual(json.loads(system.read_text())["refreshRate"], 120)
        owner.kill()
        owner.wait(timeout=5)
        self.wait_for(self.clean)
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])
        self.assertEqual(json.loads(system.read_text()), original)

    def test_newer_preference_survives_owner_crash(self):
        owner = self.armed_owner()
        self.write_keyboard(True, True)
        owner.kill()
        owner.wait(timeout=5)
        self.wait_for(self.clean)
        self.assertTrue(json.loads(self.keyboard.read_text())["live"])

    def test_restarted_helper_recovers_pending_work(self):
        owner = self.armed_owner()
        self.processes[0].kill()
        self.processes[0].wait(timeout=5)
        owner.kill()
        owner.wait(timeout=5)
        self.assertFalse(self.clean())
        self.spawn("--watch")
        self.wait_for(self.clean)
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])

    def test_new_boot_does_not_replay_old_live_mode(self):
        owner = self.armed_owner()
        self.write_keyboard(False, False, boot="new-boot")
        owner.kill()
        owner.wait(timeout=5)
        self.wait_for(self.clean)
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])

    def test_missing_helper_prevents_any_temporary_change(self):
        owner = self.spawn("--fixture-owner")
        self.assertNotEqual(owner.wait(timeout=10), 0)
        self.assertFalse((self.root / "armed").exists())
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])

    def test_unknown_options_cannot_fall_back_to_live_recovery(self):
        process = self.spawn("--watch", "--unknown-test-option")
        self.assertNotEqual(process.wait(timeout=5), 0)
        self.assertFalse((self.root / "GameMode").exists())
        self.assertFalse((self.root / "GameModeRecovery").exists())
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])

    def test_exported_tool_survives_bundle_deletion_and_does_not_replay_clean_snapshot(self):
        owner = self.armed_owner()
        kit = self.root / "Exported Kit"
        fake_app = self.root / "Removed.app"
        fake_app.mkdir()
        copied_helper = fake_app / "GameModeRecovery"
        shutil.copy2(HELPER, copied_helper)
        subprocess.run([str(copied_helper), "--fixture-root", str(self.root), "--export-kit", str(kit)], check=True, capture_output=True, env=self.environment)
        self.assertTrue((kit / "GameModeRecovery").is_file())
        busy = subprocess.run([str(kit / "GameModeRecovery"), "--fixture-root", str(self.root), "--restore", "--kit", str(kit)], capture_output=True, env=self.environment)
        self.assertNotEqual(busy.returncode, 0, "Exported tool must not restore a live owner's session")
        self.assertTrue(json.loads(self.keyboard.read_text())["live"])
        self.processes[0].kill()
        self.processes[0].wait(timeout=5)
        owner.kill()
        owner.wait(timeout=5)
        # The exported executable must be independent of the main app's files.
        shutil.rmtree(fake_app)
        subprocess.run([str(kit / "GameModeRecovery"), "--fixture-root", str(self.root), "--restore", "--kit", str(kit)], check=True, capture_output=True, env=self.environment)
        self.assertTrue(self.clean())
        self.assertFalse(json.loads(self.keyboard.read_text())["live"])
        self.write_keyboard(True, True)
        subprocess.run([str(kit / "GameModeRecovery"), "--fixture-root", str(self.root), "--restore", "--kit", str(kit)], check=True, capture_output=True, env=self.environment)
        self.assertTrue(json.loads(self.keyboard.read_text())["live"], "An old export must not replay a completed session")

    def test_export_refuses_missing_current_journal(self):
        owner = self.armed_owner()
        kit = self.root / "Exported Kit"
        subprocess.run([str(HELPER), "--fixture-root", str(self.root), "--export-kit", str(kit)], check=True, capture_output=True, env=self.environment)
        self.processes[0].kill()
        self.processes[0].wait(timeout=5)
        owner.kill()
        owner.wait(timeout=5)
        shutil.rmtree(self.root / "GameMode")
        result = subprocess.run([str(kit / "GameModeRecovery"), "--fixture-root", str(self.root), "--restore", "--kit", str(kit)], capture_output=True, env=self.environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"current recovery record is missing", result.stderr)
        self.assertTrue(json.loads(self.keyboard.read_text())["live"])


if __name__ == "__main__":
    if "GAMEMODE_RECOVERY_HELPER" in os.environ and not HELPER.is_file():
        raise SystemExit("Configured recovery helper is missing")
    unittest.main()
