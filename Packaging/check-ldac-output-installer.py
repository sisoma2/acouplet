import fcntl
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from check_runner import CheckCases
from check_stubs import StubExecutable

packaging = Path(__file__).parent
identifier = "dev.baglayan.Acouplet.LDACOutput"
legacy_identifier = "local.xm5control.ldac-output-driver"
installed_path = "/Library/Audio/Plug-Ins/HAL/AcoupletLDACOutput.driver"
legacy_path = "/Library/Audio/Plug-Ins/HAL/XM5LDACOutput.driver"
support_path = "/Library/Application Support/Acouplet"
team = "ABCDE12345"
components = plistlib.loads(
    (packaging / "LDACOutputInstaller/components.plist").read_bytes()
)
assert (
    len(components) == 1
    and components[0]["RootRelativeBundlePath"] == "AcoupletLDACOutput.driver"
)
assert (
    components[0]["BundleIsRelocatable"] is False
    and components[0]["BundleHasStrictIdentifier"] is True
)
stub_source = r"""#!/usr/bin/python3
from pathlib import Path
import json, os, plistlib, re, shutil, sys
root = Path(os.environ['ACOUPLET_OUTPUT_INSTALL_CHECK_ROOT'])
args = sys.argv[1:]
name = Path(sys.argv[0]).name
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
if name == 'PlistBuddy':
    value = plistlib.loads(Path(args[2]).read_bytes())
    print(value[args[1].removeprefix('Print :')])
elif name == 'codesign':
    bundle = Path(args[-1])
    assert bundle.is_relative_to(root), args
    signature = json.loads((bundle / 'signature.json').read_text())
    if args[0] == '--display':
        print('TeamIdentifier=' + signature['team'], file=sys.stderr)
    else:
        assert args[:4] == ['--verify', '--deep', '--strict', '--all-architectures'], args
        assert args[4].startswith('--test-requirement='), args
        expected = re.search(r'subject\.OU\] = "([A-Z0-9]{10})"', args[4])
        certificate = re.search(r'certificate leaf = H"([A-Fa-f0-9]{40})"', args[4])
        identity = re.search(r'identifier "([^"]+)"', args[4])
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        sys.exit(0 if signature['valid'] and (not expected or signature['team'] == expected[1]) and (not certificate or signature.get('certificate') == certificate[1]) and (not identity or info['CFBundleIdentifier'] == identity[1]) else 23)
elif name == 'pgrep':
    process = os.environ.get('ACOUPLET_OUTPUT_INSTALL_CHECK_PROCESS', '')
    if process:
        count = sum(json.loads(line)[0] == 'pgrep' for line in (root / 'commands.jsonl').read_text().splitlines())
        if os.environ.get('ACOUPLET_OUTPUT_INSTALL_CHECK_RESPAWN') and count == 1: sys.exit(1)
        sys.exit(0 if re.search(args[-1], process) else 1)
    running = os.environ.get('ACOUPLET_OUTPUT_INSTALL_CHECK_RUNNING', '')
    sys.exit(0 if running and running in args[-1] else 1)
elif name == 'pkgutil':
    assert args[0] in ('--pkg-info', '--forget') and args[1] in (
        'dev.baglayan.Acouplet.LDACOutput', 'local.xm5control.ldac-output-driver'), args
    if args[0] == '--pkg-info':
        sys.exit(0 if os.environ.get('ACOUPLET_OUTPUT_INSTALL_CHECK_RECEIPTS', 'yes') == 'yes' else 1)
elif name == 'rm':
    assert args[0] == '-rf' and len(args) == 2, args
    path = Path(args[1])
    assert path.is_relative_to(root / 'HAL') and not path.is_symlink(), args
    shutil.rmtree(path)
elif name == 'install':
    assert args[:8] == ['-d', '-o', 'root', '-g', 'wheel', '-m', '755', str(root / 'support')], args
    (root / 'support').mkdir(mode=0o755)
elif name == 'chown':
    assert args == ['root:wheel', str(root / 'support/ldac-route-owner.lock')], args
elif name == 'stat':
    assert args[0] == '-f' and args[1] in ('%u:%Lp', '%u:%Lp:%l'), args
    path = Path(args[2])
    assert path in (root / 'support', root / 'support/ldac-route-owner.lock'), args
    metadata = path.stat()
    uid = 501 if os.environ.get('ACOUPLET_OUTPUT_INSTALL_CHECK_FOREIGN') == path.name else 0
    value = str(uid) + ':' + format(metadata.st_mode & 0o7777, 'o')
    if args[1].endswith(':%l'): value += ':' + str(metadata.st_nlink)
    print(value)
else:
    raise AssertionError(args)
"""
stub_executable = StubExecutable(stub_source)
checks = CheckCases("check-ldac-output-installer fixtures")


def make_bundle(path, legacy=False, state="owned"):
    executable = "XM5VirtualOutput" if legacy else "AcoupletVirtualOutput"
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/MacOS" / executable).write_text("fixture")
    (path / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "unrelated"
                if state == "foreign"
                else legacy_identifier
                if legacy
                else identifier,
                "CFBundleExecutable": "unrelated"
                if state == "executable-foreign"
                else executable,
                "AcoupletLDACDriverRevision": 7 if state == "old-revision" else 8,
            }
        )
    )
    (path / "signature.json").write_text(
        json.dumps(
            {
                "team": "not set"
                if state in ("private", "wrong-certificate")
                else "ZZZZZ99999"
                if state == "wrong-team"
                else team,
                "certificate": "B" * 40 if state == "wrong-certificate" else "A" * 40,
                "valid": state != "bad-signature",
            }
        )
    )
    if state.startswith("symlink"):
        relative = {
            "symlink": ".",
            "symlink-contents": "Contents",
            "symlink-info": "Contents/Info.plist",
            "symlink-macos": "Contents/MacOS",
            "symlink-executable": "Contents/MacOS/" + executable,
        }[state]
        target = path if relative == "." else path / relative
        moved = path.parent / (path.name + "-" + state)
        target.rename(moved)
        target.symlink_to(moved)


def prepare(root):
    (root / "HAL/Unrelated.driver").mkdir(parents=True)
    (root / "HAL/Unrelated.driver/keep").write_text("preserve")
    for name in (
        "PlistBuddy",
        "codesign",
        "pgrep",
        "pkgutil",
        "rm",
        "install",
        "chown",
        "stat",
    ):
        stub = root / name
        stub_executable.link(stub)
    return {**os.environ, "ACOUPLET_OUTPUT_INSTALL_CHECK_ROOT": str(root)}


def make_app(root, legacy=False, state="owned"):
    path = root / ("XM5 Control Native.app" if legacy else "Acouplet.app")
    make_bundle(path, state=state)
    info = path / "Contents/Info.plist"
    value = plistlib.loads(info.read_bytes())
    value["CFBundleIdentifier"] = (
        "unrelated"
        if state == "foreign"
        else "local.xm5control.native"
        if legacy
        else "dev.baglayan.Acouplet"
    )
    value["CFBundleExecutable"] = "XM5 Control" if legacy else "Acouplet"
    if state in ("private", "wrong-certificate"):
        value["AcoupletSigningCertificateSHA1"] = "A" * 40
        value["AcoupletDistribution"] = "development"
    info.write_bytes(plistlib.dumps(value))
    if state == "missing":
        shutil.rmtree(path)
    if state == "no-team":
        (path / "signature.json").write_text(
            json.dumps({"team": "not set", "valid": True})
        )


def run_script(root, name, environment, volume="/", signing_team=team, certificate=""):
    source = (packaging / name).read_text()
    source = source.replace("@ACOUPLET_LDAC_SIGNING_TEAM_ID@", signing_team)
    source = source.replace("@ACOUPLET_LDAC_SIGNING_CERTIFICATE_SHA1@", certificate)
    source = source.replace("/usr/bin/sudo /bin/sh", "/bin/sh")
    source = source.replace(installed_path, str(root / "HAL/AcoupletLDACOutput.driver"))
    source = source.replace(legacy_path, str(root / "HAL/XM5LDACOutput.driver"))
    source = source.replace(support_path, str(root / "support"))
    source = source.replace("/Applications/Acouplet.app", str(root / "Acouplet.app"))
    source = source.replace(
        "/Applications/XM5 Control Native.app", str(root / "XM5 Control Native.app")
    )
    for path in (
        "/usr/libexec/PlistBuddy",
        "/usr/bin/codesign",
        "/usr/bin/pgrep",
        "/usr/sbin/pkgutil",
        "/bin/rm",
        "/usr/bin/install",
        "/usr/sbin/chown",
        "/usr/bin/stat",
    ):
        source = source.replace(path, str(root / Path(path).name))
    script = root / Path(name).name
    script.write_text(source)
    command = (
        ["/bin/zsh", str(script)]
        if name.endswith(".command")
        else ["/bin/sh", str(script), "/fixture.pkg", "/", volume]
    )
    return subprocess.run(
        command, check=False, env=environment, text=True, capture_output=True
    )


def commands(root):
    log = root / "commands.jsonl"
    return (
        [json.loads(line) for line in log.read_text().splitlines()]
        if log.exists()
        else []
    )


invalid_states = (
    "foreign",
    "executable-foreign",
    "symlink",
    "symlink-contents",
    "symlink-info",
    "symlink-macos",
    "symlink-executable",
    "wrong-team",
    "bad-signature",
)


def check_preinstall(legacy, state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-preinstall-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        driver = (
            root
            / "HAL"
            / ("XM5LDACOutput.driver" if legacy else "AcoupletLDACOutput.driver")
        )
        if state != "absent":
            make_bundle(driver, legacy, state)
        result = run_script(root, "LDACOutputInstaller/preinstall", environment)
        assert (result.returncode == 0) == (state in ("absent", "owned")), (
            legacy,
            state,
            result.stderr,
        )
        assert (driver.exists() or driver.is_symlink()) == (state != "absent")
        assert not any(command[0] in ("rm", "pkgutil") for command in commands(root))
        assert (
            run_script(
                root, "LDACOutputInstaller/preinstall", environment, "/other-volume"
            ).returncode
            != 0
        )
        assert (root / "HAL/Unrelated.driver/keep").read_text() == "preserve"


for legacy in (False, True):
    for state in ("absent", "owned", *invalid_states):
        checks.add(
            "preinstall/" + str(legacy) + "/" + str(state),
            check_preinstall,
            legacy,
            state,
        )


def check_private_certificate(script, certificate, state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-private-driver-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        driver = root / "HAL/AcoupletLDACOutput.driver"
        make_bundle(driver, state=state)
        if script.endswith(".command"):
            make_app(root, state="private")
            info_path = root / "Acouplet.app/Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["AcoupletSigningCertificateSHA1"] = certificate
            info_path.write_bytes(plistlib.dumps(info))
        result = run_script(
            root, script, environment, signing_team="", certificate=certificate
        )
        succeeds = certificate == "A" * 40 and state == "private"
        assert (result.returncode == 0) == succeeds, (
            script,
            certificate,
            state,
            result.stderr,
        )
        if not succeeds:
            assert driver.is_dir()
            assert not any(
                command[0] in ("rm", "pkgutil") for command in commands(root)
            )
        assert (root / "HAL/Unrelated.driver/keep").read_text() == "preserve"


for private_script in (
    "LDACOutputInstaller/preinstall",
    "LDACOutputInstaller/postinstall",
    "LDACOutputUninstaller/postinstall",
    "Uninstall LDAC Output.command",
):
    for private_certificate, private_state in (
        ("A" * 40, "private"),
        ("A" * 40, "wrong-certificate"),
        ("invalid", "private"),
        ("A" * 39 + '"', "private"),
    ):
        checks.add(
            "private/"
            + private_script
            + "/"
            + private_certificate
            + "/"
            + private_state,
            check_private_certificate,
            private_script,
            private_certificate,
            private_state,
        )


def check_signing_team(signing_team):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-signing-team-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        new_driver = root / "HAL/AcoupletLDACOutput.driver"
        old_driver = root / "HAL/XM5LDACOutput.driver"
        make_bundle(new_driver)
        make_bundle(old_driver, True)
        result = run_script(
            root,
            "LDACOutputInstaller/preinstall",
            environment,
            signing_team=signing_team,
        )
        assert result.returncode != 0 and "no valid signing team" in result.stderr, (
            signing_team,
            result.stderr,
        )
        assert new_driver.is_dir() and old_driver.is_dir() and not commands(root)


for signing_team in ("", "not set", "ABCDE1234", "ABCDE123456", "abcde12345"):
    checks.add("signing-team/" + str(signing_team), check_signing_team, signing_team)


def check_postinstall(legacy, state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-postinstall-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        new_driver = root / "HAL/AcoupletLDACOutput.driver"
        old_driver = root / "HAL/XM5LDACOutput.driver"
        if legacy or state != "absent":
            make_bundle(new_driver, state="owned" if legacy else state)
        if not legacy or state != "absent":
            make_bundle(old_driver, True, state if legacy else "owned")
        result = run_script(root, "LDACOutputInstaller/postinstall", environment)
        succeeds = state == "owned" or (legacy and state in ("absent", "old-revision"))
        assert (result.returncode == 0) == succeeds, (
            legacy,
            state,
            result.stdout,
            result.stderr,
        )
        assert (old_driver.exists() or old_driver.is_symlink()) == (
            not succeeds and (not legacy or state != "absent")
        )
        assert new_driver.exists() == (legacy or state != "absent")
        recorded = commands(root)
        assert (["pkgutil", "--forget", legacy_identifier] in recorded) == succeeds
        if succeeds:
            assert "Restart your Mac" in result.stdout
            if state != "absent":
                verified = [
                    index
                    for index, command in enumerate(recorded)
                    if command[:2] == ["codesign", "--verify"]
                ]
                removal = next(
                    index
                    for index, command in enumerate(recorded)
                    if command[0] == "rm"
                )
                assert len(verified) == 2 and max(verified) < removal
        else:
            assert not any(command[0] in ("rm", "pkgutil") for command in recorded)
        assert (root / "HAL/Unrelated.driver/keep").read_text() == "preserve"


for legacy in (False, True):
    for state in ("absent", "owned", "old-revision", *invalid_states):
        checks.add(
            "postinstall/" + str(legacy) + "/" + str(state),
            check_postinstall,
            legacy,
            state,
        )


def check_route_owner(state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-route-owner-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        new_driver = root / "HAL/AcoupletLDACOutput.driver"
        old_driver = root / "HAL/XM5LDACOutput.driver"
        make_bundle(new_driver)
        make_bundle(old_driver, True)
        support = root / "support"
        lock = support / "ldac-route-owner.lock"
        if state == "symlink-directory":
            support.symlink_to(root / "HAL", target_is_directory=True)
        elif state == "file-directory":
            support.touch()
        elif state != "absent":
            support.mkdir(mode=0o777 if state == "writable-directory" else 0o755)
            if state == "writable-directory":
                support.chmod(0o777)
            if state == "symlink-file":
                lock.symlink_to(root / "missing")
            elif state == "directory-file":
                lock.mkdir()
            elif state == "fifo-file":
                os.mkfifo(lock)
            else:
                lock.touch(mode=0o444 if state == "read-only" else 0o644)
                if state == "writable-file":
                    lock.chmod(0o666)
                if state == "hardlink-file":
                    os.link(lock, support / "other")
        if state.startswith("foreign-"):
            environment["ACOUPLET_OUTPUT_INSTALL_CHECK_FOREIGN"] = (
                support.name if state.endswith("directory") else lock.name
            )
        succeeds = state in ("absent", "owned", "read-only")
        inode = lock.stat().st_ino if succeeds and lock.exists() else None
        descriptor = (
            os.open(lock, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW) if inode else None
        )
        try:
            if descriptor is not None:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = run_script(root, "LDACOutputInstaller/postinstall", environment)
            assert (result.returncode == 0) == succeeds, (
                state,
                result.stdout,
                result.stderr,
            )
            assert old_driver.exists() == (not succeeds)
            if succeeds:
                assert (
                    lock.is_file()
                    and not lock.is_symlink()
                    and lock.read_bytes() == b""
                )
                assert lock.stat().st_mode & 0o777 == (
                    0o444 if state == "read-only" else 0o644
                )
                if inode:
                    assert lock.stat().st_ino == inode
                    assert not any(
                        command[0] in ("install", "chown") for command in commands(root)
                    )
                    other = os.open(lock, os.O_RDONLY)
                    try:
                        try:
                            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            pass
                        else:
                            raise AssertionError("Upgrade replaced a locked inode")
                    finally:
                        os.close(other)
                inode = lock.stat().st_ino
                for removal in (
                    "LDACOutputUninstaller/postinstall",
                    "Uninstall LDAC Output.command",
                ):
                    if new_driver.exists():
                        make_app(root)
                    result = run_script(root, removal, environment)
                    assert result.returncode == 0, (removal, result.stderr)
                    assert lock.exists() and lock.stat().st_ino == inode
            else:
                assert not any(
                    command[0] in ("rm", "pkgutil") for command in commands(root)
                )
        finally:
            if descriptor is not None:
                os.close(descriptor)


for state in (
    "absent",
    "owned",
    "read-only",
    "symlink-directory",
    "file-directory",
    "foreign-directory",
    "writable-directory",
    "symlink-file",
    "directory-file",
    "fifo-file",
    "foreign-file",
    "writable-file",
    "hardlink-file",
):
    checks.add("route-owner/" + str(state), check_route_owner, state)


def check_remove(legacy, state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-removal-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        make_app(root)
        new_driver = root / "HAL/AcoupletLDACOutput.driver"
        old_driver = root / "HAL/XM5LDACOutput.driver"
        if legacy or state != "absent":
            make_bundle(new_driver, state="owned" if legacy else state)
        if not legacy or state != "absent":
            make_bundle(old_driver, True, state if legacy else "owned")
        result = run_script(root, "Uninstall LDAC Output.command", environment)
        succeeds = state in ("owned", "absent")
        assert (result.returncode == 0) == succeeds, (
            legacy,
            state,
            result.stdout,
            result.stderr,
        )
        for driver in (new_driver, old_driver):
            assert (driver.exists() or driver.is_symlink()) == (not succeeds)
        recorded = commands(root)
        for receipt in (identifier, legacy_identifier):
            assert (["pkgutil", "--forget", receipt] in recorded) == succeeds
        if succeeds:
            assert (
                "Restart your Mac" in result.stdout
                and "Core Audio was not restarted" in result.stdout
            )
            verified = [
                index
                for index, command in enumerate(recorded)
                if command[:2] == ["codesign", "--verify"]
            ]
            removed = [
                index for index, command in enumerate(recorded) if command[0] == "rm"
            ]
            assert max(verified) < min(removed)
        else:
            assert not any(command[0] in ("rm", "pkgutil") for command in recorded)
        assert (root / "HAL/Unrelated.driver/keep").read_text() == "preserve"


for legacy in (False, True):
    for state in ("absent", "owned", *invalid_states):
        checks.add(
            "remove/" + str(legacy) + "/" + str(state), check_remove, legacy, state
        )


def check_owner(state, legacy):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-owner-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        make_app(root, legacy, state)
        driver = (
            root
            / "HAL"
            / ("XM5LDACOutput.driver" if legacy else "AcoupletLDACOutput.driver")
        )
        make_bundle(driver, legacy)
        if state.startswith("running-"):
            environment["ACOUPLET_OUTPUT_INSTALL_CHECK_RUNNING"] = (
                "XM5 Control" if state == "running-legacy" else "Acouplet"
            )
        if state == "no-receipts":
            environment["ACOUPLET_OUTPUT_INSTALL_CHECK_RECEIPTS"] = "no"
        result = run_script(root, "Uninstall LDAC Output.command", environment)
        succeeds = state in ("owned", "no-receipts")
        assert (result.returncode == 0) == succeeds, (
            legacy,
            state,
            result.stdout,
            result.stderr,
        )
        assert driver.exists() != succeeds
        recorded = commands(root)
        if not succeeds:
            assert not any(command[0] in ("rm", "pkgutil") for command in recorded)
        if state == "no-receipts":
            assert not any(
                command[:2] == ["pkgutil", "--forget"] for command in recorded
            )


for state in (
    "owned",
    "missing",
    "foreign",
    "bad-signature",
    "wrong-team",
    "no-team",
    "symlink",
    "symlink-contents",
    "symlink-info",
    "running-new",
    "running-legacy",
    "no-receipts",
):
    for legacy in (False, True):
        checks.add(
            "owner/" + str(state) + "/" + str(legacy), check_owner, state, legacy
        )

with tempfile.TemporaryDirectory(prefix="acouplet-output-empty-check-") as directory:
    root = Path(directory)
    result = run_script(root, "Uninstall LDAC Output.command", prepare(root))
    assert result.returncode == 0, result.stderr
    assert not any(command[0] in ("codesign", "rm") for command in commands(root))


def check_remove_package(legacy, state):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-removal-package-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        new_driver = root / "HAL/AcoupletLDACOutput.driver"
        old_driver = root / "HAL/XM5LDACOutput.driver"
        if legacy or state != "absent":
            make_bundle(new_driver, state="owned" if legacy else state)
        if not legacy or state != "absent":
            make_bundle(old_driver, True, state if legacy else "owned")
        result = run_script(root, "LDACOutputUninstaller/postinstall", environment)
        succeeds = state in ("absent", "owned")
        assert (result.returncode == 0) == succeeds, (legacy, state, result.stderr)
        recorded = commands(root)
        if succeeds:
            assert not new_driver.exists() and not old_driver.exists()
            verified = [
                index
                for index, command in enumerate(recorded)
                if command[:2] == ["codesign", "--verify"]
            ]
            removed = [
                index for index, command in enumerate(recorded) if command[0] == "rm"
            ]
            assert max(verified) < min(removed)
            assert [
                command[1:]
                for command in recorded
                if command[:2] == ["pkgutil", "--forget"]
            ] == [["--forget", identifier], ["--forget", legacy_identifier]]
            assert (
                "Restart your Mac" in result.stdout
                and "Core Audio was not restarted" in result.stdout
            )
        else:
            assert not any(command[0] in ("rm", "pkgutil") for command in recorded)
        assert (root / "HAL/Unrelated.driver/keep").read_text() == "preserve"


for legacy in (False, True):
    for state in ("absent", "owned", *invalid_states):
        checks.add(
            "remove-package/" + str(legacy) + "/" + str(state),
            check_remove_package,
            legacy,
            state,
        )


def check_process(process, respawn):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-removal-running-check-"
    ) as directory:
        root = Path(directory)
        environment = prepare(root)
        environment["ACOUPLET_OUTPUT_INSTALL_CHECK_PROCESS"] = process
        if respawn:
            environment["ACOUPLET_OUTPUT_INSTALL_CHECK_RESPAWN"] = "1"
        driver = root / "HAL/AcoupletLDACOutput.driver"
        make_bundle(driver)
        result = run_script(root, "LDACOutputUninstaller/postinstall", environment)
        assert result.returncode != 0 and "Nothing was removed" in result.stderr, (
            process,
            result.stderr,
        )
        assert driver.exists() and not any(
            command[0] in ("rm", "pkgutil") for command in commands(root)
        )


for process in (
    "/Applications/Acouplet.app/Contents/MacOS/Acouplet --background-service",
    "/Users/guest/Downloads/Renamed.app/Contents/MacOS/Acouplet",
    "/Applications/XM5 Control Native.app/Contents/MacOS/XM5 Control",
    "/Applications/XM5 Control.app/Contents/MacOS/XM5 Control",
    "/Applications/Acouplet.app/Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio",
    *(
        "/Applications/Acouplet.app/Contents/Helpers/" + name
        for name in (
            "LDACSignaling",
            "LDACMediaTransport",
            "SonyAudioConnection",
            "LDACLogObserver",
        )
    ),
):
    for respawn in (False, True):
        checks.add(
            "process/" + str(process) + "/" + str(respawn),
            check_process,
            process,
            respawn,
        )


def check_invalid_volume(signing_team, volume):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-output-removal-boundary-check-"
    ) as directory:
        root = Path(directory)
        driver = root / "HAL/AcoupletLDACOutput.driver"
        make_bundle(driver)
        result = run_script(
            root,
            "LDACOutputUninstaller/postinstall",
            prepare(root),
            volume,
            signing_team,
        )
        assert result.returncode != 0 and driver.exists() and not commands(root), (
            result.stderr
        )


for signing_team, volume in [
    ("", "/"),
    ("not set", "/"),
    ("abcde12345", "/"),
    (team, "/other-volume"),
]:
    checks.add(
        "invalid-volume/" + str(signing_team) + "/" + str(volume),
        check_invalid_volume,
        signing_team,
        volume,
    )


def check_source(name):
    source = (packaging / name).read_text()
    assert (
        "coreaudiod" not in source
        and "/sbin/reboot" not in source
        and "killall" not in source
    )


for name in (
    "LDACOutputInstaller/preinstall",
    "LDACOutputInstaller/postinstall",
    "Uninstall LDAC Output.command",
    "LDACOutputUninstaller/postinstall",
):
    checks.add("source/" + str(name), check_source, name)


if __name__ == "__main__":
    checks.main()
