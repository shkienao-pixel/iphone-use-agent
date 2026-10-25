#!/usr/bin/env python3
"""Regression for operator liveness; no simulator, model, credential or UI calls."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("simulator_live_transport", ROOT / "Tools/SimulatorLab/live.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class OperatorLiveness(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="sela-operator-liveness-")
        self.addCleanup(self.folder.cleanup)
        self.session = pathlib.Path(self.folder.name) / "session.json"
        self.session.write_text(json.dumps({"uiSession": "test", "appSession": "test"}))
        self.runner = str(pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices" / live.DEVICE /
                          "data/Containers/Bundle/Application/12345678-1234-1234-1234-123456789ABC" /
                          "SimulatorLiveOperatorUITests-Runner.app/SimulatorLiveOperatorUITests-Runner")

    def rejected_before_any_ui_file_access(self, command_lines):
        with patch.object(live, "SESSION_FILE", self.session), \
             patch.object(live.subprocess, "check_output", return_value=command_lines), \
             patch.object(live, "ui_root", side_effect=AssertionError("Liveness guard reached UI storage")) as storage:
            with self.assertRaisesRegex(RuntimeError, "UI operator has ended"):
                live.ui("ping", timeout=.01)
            storage.assert_not_called()

    def test_shell_quoting_runner_path_is_not_a_live_operator(self):
        self.rejected_before_any_ui_file_access("/bin/zsh -c python3 - <<'PY' " + self.runner + "\n")

    def test_python_printing_runner_path_is_not_a_live_operator(self):
        self.rejected_before_any_ui_file_access("python3 -c print(" + repr(self.runner) + ")\n")

    def test_runner_on_another_device_is_not_our_operator(self):
        self.rejected_before_any_ui_file_access(self.runner.replace(live.DEVICE, "00000000-0000-4000-8000-000000000000") + "\n")

    def test_app_on_same_device_is_not_the_operator(self):
        self.rejected_before_any_ui_file_access(self.runner.replace("SimulatorLiveOperatorUITests-Runner", "PhoneAgent") + "\n")

    def test_empty_process_list_rejects_before_storage(self):
        self.rejected_before_any_ui_file_access("")

    def test_other_wrapper_argument_containing_path_is_not_an_executable(self):
        self.rejected_before_any_ui_file_access("/usr/bin/tee -- " + self.runner + "\n")

    def test_similarly_named_executable_is_rejected(self):
        self.rejected_before_any_ui_file_access(self.runner + "-old\n")

    def test_malformed_container_identity_is_rejected(self):
        self.rejected_before_any_ui_file_access(self.runner.replace("12345678-1234-1234-1234-123456789ABC", "not-a-container") + "\n")

    def test_actual_operator_path_reaches_session_validation(self):
        # Passing this guard grants no UI authority: the real ready/session
        # validation is the next boundary and remains mandatory.
        with patch.object(live, "SESSION_FILE", self.session), \
             patch.object(live.subprocess, "check_output", return_value=self.runner + "\n"), \
             patch.object(live, "ui_root", side_effect=RuntimeError("session validation boundary")):
            with self.assertRaisesRegex(RuntimeError, "session validation boundary"):
                live.ui("ping", timeout=.01)

    def test_actual_operator_with_arguments_reaches_session_validation(self):
        with patch.object(live, "SESSION_FILE", self.session), \
             patch.object(live.subprocess, "check_output", return_value=self.runner + " -AppleLanguages (zh-Hans)\n"), \
             patch.object(live, "ui_root", side_effect=RuntimeError("session validation boundary")):
            with self.assertRaisesRegex(RuntimeError, "session validation boundary"):
                live.ui("ping", timeout=.01)


if __name__ == "__main__":
    unittest.main(verbosity=2)
