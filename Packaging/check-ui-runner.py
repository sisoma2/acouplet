import importlib.util
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "gui_runner", Path(__file__).with_name("check-ui.py")
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

with (
    patch.object(runner, "run_in_vm") as vm,
    patch.object(runner, "require_guest") as guest,
):
    runner.main(["--ui-vm", "base", "--only-testing", "AcoupletUITests/testExample"])
    assert vm.call_args.args[1:] == ("base", ["AcoupletUITests/testExample"], 1)
    guest.assert_not_called()

with (
    patch.object(runner, "require_guest", side_effect=ValueError("host rejected")),
    patch.object(runner.subprocess, "run") as run,
):
    try:
        runner.main([])
    except ValueError as error:
        assert str(error) == "host rejected"
    else:
        raise AssertionError("Host GUI automation was accepted")
    run.assert_not_called()

for arguments in (["--jobs", "0"], ["--only-testing", "AcoupletTests"]):
    with patch.object(runner, "require_guest") as guest:
        try:
            runner.main(arguments)
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError("Invalid GUI arguments were accepted")
        guest.assert_not_called()

with tempfile.TemporaryDirectory(prefix="acouplet-gui-runner-") as temporary:
    repo = Path(temporary)
    dependency = repo / ".build/Sparkle-2.10.0/Sparkle.framework/Resources/Info.plist"
    dependency.parent.mkdir(parents=True)
    dependency.touch()
    with (
        patch.object(runner, "__file__", str(repo / "Packaging/check-ui.py")),
        patch.object(runner, "require_guest"),
        patch.object(runner.subprocess, "run") as run,
    ):
        for passed, failed, accepted in [(1, 0, True), (0, 0, False), (1, 1, False)]:
            with patch.object(
                runner.subprocess,
                "check_output",
                return_value=json.dumps(
                    {"passedTests": passed, "failedTests": failed}
                ).encode(),
            ):
                try:
                    runner.main([])
                except ValueError:
                    assert not accepted
                else:
                    assert accepted
                command = run.call_args.args[0]
                assert command[command.index("-scheme") + 1] == "Acouplet UI Tests"
                assert command[command.index("-parallel-testing-enabled") + 1] == "NO"
                assert "-only-testing:AcoupletUITests" in command

print(
    "GUI runner checks passed: VM delegation, host rejection, selector validation and result admission."
)
