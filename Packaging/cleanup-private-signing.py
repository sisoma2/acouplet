import subprocess
import sys
from pathlib import Path

COMMAND_TIMEOUT_SECONDS = 20


def run_security(*arguments):
    print("Signing cleanup: security " + " ".join(arguments), flush=True)
    try:
        subprocess.run(
            ["/usr/bin/security", *arguments],
            check=True,
            stdin=subprocess.DEVNULL,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (subprocess.SubprocessError, OSError) as error:
        print("::warning::Signing cleanup: " + str(error), flush=True)
        return False
    return True


def cleanup(directory):
    directory = Path(directory)
    identity = directory / "acouplet-private.p12"
    keychain = directory / "acouplet-private.keychain-db"
    certificate = directory / "acouplet-private.pem"
    identity.unlink(missing_ok=True)
    keychain_removed = True
    trust_removed = True
    try:
        if certificate.exists():
            trust_removed = run_security("remove-trusted-cert", "-d", str(certificate))
    finally:
        if keychain.exists():
            keychain_removed = run_security("delete-keychain", str(keychain))
            keychain.unlink(missing_ok=True)
        if trust_removed:
            certificate.unlink(missing_ok=True)
    if not keychain_removed or not trust_removed:
        raise RuntimeError(
            "Credential files removed, but Security cleanup failed. "
            "Any remaining public certificate is retained for a trust-removal retry."
        )
    print("Private signing credentials removed.", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: cleanup-private-signing.py RUNNER_TEMP")
    cleanup(sys.argv[1])
