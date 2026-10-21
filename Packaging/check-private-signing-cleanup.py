import runpy
import subprocess
import tempfile
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

script = Path(__file__).with_name("cleanup-private-signing.py")
module = runpy.run_path(str(script))
cleanup = module["cleanup"]


def check_cleanup(failure):
    with tempfile.TemporaryDirectory(prefix="acouplet-signing-cleanup-") as temporary:
        directory = Path(temporary)
        identity = directory / "acouplet-private.p12"
        keychain = directory / "acouplet-private.keychain-db"
        certificate = directory / "acouplet-private.pem"
        for path in (identity, keychain, certificate):
            path.write_text("fixture")
        unrelated = directory / "keep"
        unrelated.write_text("preserved")
        commands = []

        def run(command, **options):
            assert not identity.exists()
            assert options == {
                "check": True,
                "stdin": subprocess.DEVNULL,
                "timeout": 20,
            }
            commands.append(command)
            if command[1] == "delete-keychain":
                if failure == "keychain-timeout":
                    raise subprocess.TimeoutExpired(command, 20)
                keychain.unlink()
            else:
                assert not keychain.exists()
                assert certificate.exists()
                if failure == "trust-timeout":
                    raise subprocess.TimeoutExpired(command, 20)
                if failure == "trust-denied":
                    raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        output = StringIO()
        with patch("subprocess.run", side_effect=run), redirect_stdout(output):
            try:
                cleanup(directory)
            except RuntimeError:
                assert failure == "keychain-timeout"
            else:
                assert failure != "keychain-timeout"
        assert commands == [
            ["/usr/bin/security", "delete-keychain", str(keychain)],
            ["/usr/bin/security", "remove-trusted-cert", "-d", str(certificate)],
        ]
        assert not any(path.exists() for path in (identity, keychain, certificate))
        assert unrelated.read_text() == "preserved"
        assert ("::warning::" in output.getvalue()) == (failure is not None)
        with patch("subprocess.run") as run, redirect_stdout(StringIO()):
            cleanup(directory)
        run.assert_not_called()


for failure in (None, "trust-timeout", "trust-denied", "keychain-timeout"):
    check_cleanup(failure)

with tempfile.TemporaryDirectory(prefix="acouplet-signing-cleanup-") as temporary:
    result = subprocess.run(
        ["/usr/bin/python3", str(script), temporary],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert "Private signing credentials removed." in result.stdout

print("Signing cleanup order, bounded Security commands, failures and retries: passed")
