import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from check_runner import CheckCases
from check_stubs import StubExecutable

packaging = Path(__file__).parent
native_label = "dev.baglayan.Acouplet.agent"
legacy_label = "local.xm5control.native.agent"
older_label = "local.xm5control.agent"
stub_source = r"""#!/usr/bin/python3
from pathlib import Path
import json, os, plistlib, re, shutil, subprocess, sys
root = Path(os.environ['ACOUPLET_INSTALL_CHECK_ROOT'])
mode = os.environ['ACOUPLET_INSTALL_CHECK_MODE']
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
state_file = root / 'state.json'
process_file = root / 'processes.json'
if name == 'PlistBuddy':
    value = plistlib.loads(Path(args[2]).read_bytes())
    for key in args[1].removeprefix('Print :').split(':'):
        value = value[int(key)] if isinstance(value, list) else value[key]
    print(value)
elif name == 'ditto':
    shutil.copytree(args[0], args[1])
elif name == 'codesign':
    target = Path(args[-1])
    team = (target / 'team').read_text() if (target / 'team').exists() else 'ABCDE12345'
    if args[0] == '--display': print('TeamIdentifier=' + team, file=sys.stderr)
    for argument in args:
        if argument.startswith('--test-requirement='):
            certificate = re.search(r'certificate leaf = H"([A-Fa-f0-9]{40})"', argument)
            if certificate:
                actual = (target / 'certificate').read_text() if (target / 'certificate').exists() else ''
                if actual != certificate[1]: sys.exit(21)
            else:
                assert 'anchor apple generic' in argument
                if team == 'not set': sys.exit(21)
                if re.search(r'subject.OU] = "([^"]+)"', argument)[1] != team: sys.exit(21)
            expected_id = re.search(r'identifier "([^"]+)"', argument)
            if expected_id and expected_id[1] != plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']: sys.exit(21)
    if mode == 'legacy-bad-signature' and 'XM5 Control Native.app' in args[-1]: sys.exit(21)
    if mode == 'installed-bad-signature' and '/Applications/Acouplet.app' in args[-1]: sys.exit(21)
    if mode == 'source-bad-signature' and '/package/Acouplet.app' in args[-1]: sys.exit(21)
    if mode == 'installed-validation-failure' and '/Applications/Acouplet.app' in args[-1] and (Path(args[-1]) / 'version').read_text() == 'new': sys.exit(21)
    if mode == 'pane-bad-signature' and args[-1].endswith('.prefPane'): sys.exit(21)
    if mode == 'pane-stage-failure' and '.prefPane.installing-' in args[-1]: sys.exit(21)
    if mode == 'staging-failure' and '.installing-' in args[-1]: sys.exit(21)
elif name == 'plutil':
    if args[-1] == '-' and mode in ('restore-app-failure', 'move-new-failure', 'restart-failure'): sys.exit(19)
    value = plistlib.loads(sys.stdin.buffer.read() if args[-1] == '-' else Path(args[-1]).read_bytes())
    if args[0] == '-convert':
        print(json.dumps(value, sort_keys=True, indent=2))
    else:
        assert args[0] == '-lint', args
elif name == 'pgrep':
    processes = json.loads(process_file.read_text())
    owners = processes.get('owner', [])
    if args[0] == '-fx':
        assert args[-1].endswith(('/Acouplet --ldac-owner', '/Acouplet --ldac-(owner|update-recovery [A-F0-9-]{36})')), args
        if not owners: sys.exit(1)
        print('\n'.join(str(pid) for pid in owners))
        sys.exit(0)
    key = 'legacy' if 'XM5 Control Native' in args[-1] else 'older' if 'XM5 Control' in args[-1] else 'native'
    # The LDAC owner worker runs the app's executable, so the app's own pattern finds it too.
    matches = processes[key] + (owners if key == 'native' else [])
    if matches:
        print('\n'.join(str(pid) for pid in matches))
    else:
        sys.exit(0 if mode == 'legacy-running' and 'XM5 Control Native' in args[-1] else 1)
elif name == 'kill':
    assert args[0] == '-0', args
    processes = json.loads(process_file.read_text())
    if mode == 'native-delayed-quit' and processes['quit_requested']:
        processes['exit_checks'] += 1
        if processes['exit_checks'] == 3: processes['native'] = []
        process_file.write_text(json.dumps(processes))
    sys.exit(0 if any(int(args[1]) in processes[key] for key in ('native', 'legacy', 'older')) else 1)
elif name == 'osascript':
    script = sys.stdin.read()
    if args == ['-', 'dev.baglayan.Acouplet']:
        assert 'with timeout of 30 seconds' in script
        if mode in ('native-quit-declined', 'native-quit-timeout'): sys.exit(27)
        processes = json.loads(process_file.read_text())
        request = root / 'Caches/dev.baglayan.Acouplet/ldac-update-request'
        if request.exists():
            fields = request.read_text().split()
            assert int(fields[0]) > 1 and int(fields[1]) > 0
            assert list(map(int, fields[2:])) == processes['native']
            (root / 'handoff-requested').touch()
        processes['quit_requested'] = True
        if mode == 'native-partial-quit': processes['native'] = processes['native'][1:]
        elif mode == 'native-keepalive-relaunch': processes['native'] = [102]
        elif mode not in ('native-quit-stalled', 'native-delayed-quit'): processes['native'] = []
        process_file.write_text(json.dumps(processes))
    else:
        assert args[0] == '-' and args[1] in ('local.xm5control.native', 'local.xm5control'), args
        processes = json.loads(process_file.read_text())
        if mode == 'legacy-quit-declined': sys.exit(27)
        key = 'legacy' if args[1] == 'local.xm5control.native' else 'older'
        processes[key] = []
        process_file.write_text(json.dumps(processes))
elif name == 'pluginkit':
    assert args[0] in ('-r', '-a'), args
    assert Path(args[-1]).is_dir(), args
    if mode == 'controls-unregister-failure' and args[0] == '-r': sys.exit(28)
elif name == 'lsregister':
    if mode == 'legacy-unregister-failure' and args[0] == '-u': sys.exit(22)
    if mode == 'native-register-failure' and args[0] == '-f': sys.exit(26)
elif name == 'mv':
    if mode == 'pane-commit-failure' and '.prefPane.installing-' in args[-2] and args[-1].endswith('Sony-001122334466.prefPane'): sys.exit(23)
    restoring_app = '.previous-' in args[-2] and args[-2].endswith('.app')
    restoring_plist = '.plist.previous-' in args[-2]
    moving_new = '.installing-' in args[-1] and 'Acouplet.app' in args[-2]
    if (mode == 'restore-app-failure' and restoring_app or
        mode == 'restore-plist-failure' and restoring_plist or
        mode == 'move-new-failure' and moving_new): sys.exit(23)
    sys.exit(subprocess.run(['/bin/mv', *args]).returncode)
elif name == 'rm':
    if args[-1].endswith('dev.baglayan.Acouplet.agent.plist') and mode in ('restore-app-failure', 'restore-plist-failure', 'move-new-failure', 'restart-failure'):
        sys.exit(19)
    sys.exit(subprocess.run(['/bin/rm', *args]).returncode)
elif name == 'open':
    assert args == [str(root / 'Applications/Acouplet.app')], args
    if mode == 'launch-failure': sys.exit(25)
    processes = json.loads(process_file.read_text())
    if mode != 'app-exits-on-launch': processes['native'] = [4242]
    process_file.write_text(json.dumps(processes))
elif name == 'launchctl':
    state = json.loads(state_file.read_text())
    if args[0] in ('print', 'bootout'):
        label = args[1].split('/')[-1]
        service = state[label]
        if args[0] == 'print':
            if not service['loaded']: sys.exit(1)
            running = True
            if mode in ('agent-exited', 'agent-stays-stopped') and label == 'dev.baglayan.Acouplet.agent' and service['version'] == 'new':
                # The new service is running when the bootstrap returns, then quits before the installer finishes.
                service['prints'] = service.get('prints', 0) + 1
                state_file.write_text(json.dumps(state))
                running = service['prints'] == 1 or service.get('kickstarted', False)
            print(('state = running\n\tpid = 4242' if running else 'state = not running') + '\n\tprogram = ' + service['program'])
        else:
            if mode == 'stop-failure' or mode == 'legacy-stop-failure' and label == 'local.xm5control.native.agent': sys.exit(24)
            service['loaded'] = False
            state_file.write_text(json.dumps(state))
            if label == 'dev.baglayan.Acouplet.agent':
                processes = json.loads(process_file.read_text())
                processes['native'] = []
                process_file.write_text(json.dumps(processes))
    elif args[0] == 'bootstrap':
        config = plistlib.loads(Path(args[2]).read_bytes())
        program = Path(config['ProgramArguments'][0])
        version = (program.parents[2] / 'version').read_text()
        if mode in ('bootstrap-failure', 'matching-plist-failure', 'restore-plist-failure', 'login-item-rollback') and version == 'new' or mode == 'restart-failure' and version == 'old': sys.exit(25)
        state[config['Label']] = {'loaded': True, 'program': str(program), 'version': version}
        state_file.write_text(json.dumps(state))
    elif args[0] == 'kickstart':
        service = state[args[1].split('/')[-1]]
        assert service['loaded'], args
        service['kickstarted'] = mode != 'agent-stays-stopped'
        state_file.write_text(json.dumps(state))
    else:
        raise AssertionError('Unexpected launchctl command: ' + str(args))
elif name in ('Acouplet', 'XM5 Control'):
    assert args == ['--unregister-login-item'] or name == 'Acouplet' and args in (['--register-login-item'], ['--ldac-driver-state'], ['--migrate-background-service-preferences']), args
    if args == ['--ldac-driver-state']:
        driver_state = (root / 'driver-state').read_text() if (root / 'driver-state').exists() else 'missing'
        if driver_state == 'fail': sys.exit(1)
        print(driver_state)
        sys.exit(0)
    if mode == 'helper-failure' and name == 'Acouplet': sys.exit(19)
    if args == ['--migrate-background-service-preferences']:
        (root / 'startup-preference-preserved').touch()
        sys.exit(0)
    if mode == 'legacy-helper-failure' and name == 'XM5 Control': sys.exit(19)
    if name == 'Acouplet':
        login_item = root / 'login-item.json'
        enabled = json.loads(login_item.read_text())['enabled']
        if args == ['--unregister-login-item']: print('login-item: ' + ('removed' if enabled else 'absent'))
        login_item.write_text(json.dumps({'enabled': args == ['--register-login-item']}))
elif name != 'sleep':
    raise AssertionError('Unexpected stub: ' + name)
"""
stub_executable = StubExecutable(stub_source)
sleep_executable = StubExecutable("#!/bin/sh\nexit 0\n")
checks = CheckCases("check-install fixtures")


replacements = {
    "/usr/libexec/PlistBuddy": "PlistBuddy",
    "/usr/bin/codesign": "codesign",
    "/usr/bin/ditto": "ditto",
    "/bin/launchctl": "launchctl",
    "/usr/bin/osascript": "osascript",
    "/usr/bin/open": "open",
    "/usr/bin/pgrep": "pgrep",
    "/usr/bin/plutil": "plutil",
    "/bin/kill": "kill",
    "/usr/bin/pluginkit": "pluginkit",
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister": "lsregister",
}


def fixture(root, mode):
    (root / "commands.jsonl").touch()
    package, applications, agents, stubs = (
        root / name for name in ("package", "Applications", "LaunchAgents", "stubs")
    )
    for path in (package, applications, agents, stubs):
        path.mkdir()
    for name in (*replacements.values(), "mv", "rm", "sleep"):
        stub = stubs / name
        (sleep_executable if name == "sleep" else stub_executable).link(stub)
    for parent, name, identifier, version in (
        (package, "Acouplet.app", "dev.baglayan.Acouplet", "new"),
        (applications, "Acouplet.app", "dev.baglayan.Acouplet", "old"),
        (applications, "XM5 Control Native.app", "local.xm5control.native", "legacy"),
        (applications, "XM5 Control.app", "local.xm5control", "older"),
    ):
        app = parent / name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "version").write_text(version)
        (app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": identifier})
        )
        executable = app / (
            "Contents/MacOS/Acouplet"
            if identifier == "dev.baglayan.Acouplet"
            else "Contents/MacOS/XM5 Control"
        )
        os.link(stub_executable.path, executable)
        if version == "old":
            controls = app / "Contents/PlugIns/Acouplet Controls.appex/Contents"
            controls.mkdir(parents=True)
            (controls / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "dev.baglayan.Acouplet.controls"})
            )
    if mode == "embedded-controls":
        (package / "Acouplet.app/Contents/PlugIns/Acouplet Controls.appex").mkdir(
            parents=True
        )
    if mode == "foreign-controls":
        (
            applications
            / "Acouplet.app/Contents/PlugIns/Acouplet Controls.appex/Contents/Info.plist"
        ).write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated"}))
    state = {}
    configs = {}
    for label, app_name, version in (
        (native_label, "Acouplet.app", "old"),
        (legacy_label, "XM5 Control Native.app", "legacy"),
        (older_label, "XM5 Control.app", "older"),
    ):
        program = str(
            applications
            / app_name
            / (
                "Contents/MacOS/Acouplet"
                if label == native_label
                else "Contents/MacOS/XM5 Control"
            )
        )
        configs[label] = plistlib.dumps(
            {
                "Label": label,
                "ProgramArguments": [program, "--background-service"],
                "KeepAlive": True,
                "OldConfiguration": "preserve",
            }
        )
        if (
            mode in ("matching-plist", "matching-plist-failure", "previous-plist")
            and label == native_label
        ):
            # previous-plist is the service installed before ProcessType was added; it must be rewritten.
            current = {} if mode == "previous-plist" else {"ProcessType": "Interactive"}
            configs[label] = plistlib.dumps(
                {
                    "KeepAlive": {"SuccessfulExit": False},
                    "RunAtLoad": True,
                    "LimitLoadToSessionType": "Aqua",
                    "AssociatedBundleIdentifiers": ["dev.baglayan.Acouplet"],
                    "EnvironmentVariables": {
                        "ACOUPLET_SERVICE_POLICY": "successful-exit-v1"
                    },
                    "ProgramArguments": [program, "--background-service"],
                    "Label": label,
                    **current,
                },
                fmt=plistlib.FMT_BINARY,
                sort_keys=False,
            )
        (agents / (label + ".plist")).write_bytes(configs[label])
        if (
            mode in ("matching-plist", "matching-plist-failure")
            and label == native_label
        ):
            os.utime(
                agents / (label + ".plist"),
                ns=(1650000000123456789, 1650000000123456789),
            )
        state[label] = {"loaded": True, "program": program, "version": version}
    for relative in (
        "Applications/Unrelated.app/keep",
        "Development/Acouplet.app/keep",
        "Preferences/dev.baglayan.Acouplet.plist",
        "Applications/.Acouplet.previous-interrupted.app/keep",
        "LaunchAgents/dev.baglayan.Acouplet.agent.plist.previous-interrupted",
        "LaunchAgents/unrelated.plist",
    ):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("preserve")
    if mode in ("inactive-update", "fresh-install", "login-item-rollback"):
        state[native_label]["loaded"] = False
    if mode == "fresh-install":
        shutil.rmtree(applications / "Acouplet.app")
        (agents / (native_label + ".plist")).unlink()
    if mode in ("normal-running-update", "normal-stopped-update"):
        (agents / (native_label + ".plist")).unlink()
        state[native_label]["loaded"] = False
    if mode == "login-item-rollback":
        (agents / (native_label + ".plist")).unlink()
    if mode == "orphan-service":
        (agents / (native_label + ".plist")).unlink()
    if mode in ("legacy-wrong-team", "installed-wrong-team"):
        (
            applications
            / (
                "XM5 Control Native.app"
                if mode == "legacy-wrong-team"
                else "Acouplet.app"
            )
            / "team"
        ).write_text("OTHER12345")
    if mode == "unexpected-bundle":
        (applications / "Acouplet.app/Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "unrelated"})
        )
    if mode in ("unrelated-legacy", "repurposed-legacy"):
        (applications / "XM5 Control Native.app/Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "unrelated"})
        )
    if mode == "unrelated-legacy":
        (agents / (legacy_label + ".plist")).unlink()
        state[legacy_label]["loaded"] = False
    if mode in ("unexpected-agent", "unexpected-legacy-agent"):
        label = native_label if mode == "unexpected-agent" else legacy_label
        config = plistlib.loads(configs[label])
        config["ProgramArguments"][0] = "/unrelated/program"
        (agents / (label + ".plist")).write_bytes(plistlib.dumps(config))
    if mode in ("unexpected-loaded-service", "unexpected-loaded-legacy"):
        state[native_label if mode == "unexpected-loaded-service" else legacy_label][
            "program"
        ] = "/unrelated/program"
    if mode == "symlink-agent":
        plist = agents / (native_label + ".plist")
        plist.unlink()
        plist.symlink_to(root / "Preferences/dev.baglayan.Acouplet.plist")
    (root / "state.json").write_text(json.dumps(state))
    (root / "login-item.json").write_text(
        json.dumps(
            {
                "enabled": mode
                in (
                    "success",
                    "matching-plist",
                    "previous-plist",
                    "fresh-install",
                    "inactive-update",
                    "login-item-rollback",
                    "helper-failure",
                )
            }
        )
    )
    (root / "processes.json").write_text(
        json.dumps(
            {
                "native": []
                if mode
                in (
                    "inactive-update",
                    "fresh-install",
                    "login-item-rollback",
                    "normal-stopped-update",
                )
                else [100, 101]
                if mode == "native-partial-quit"
                else [100],
                "quit_requested": False,
                "exit_checks": 0,
                "legacy": [200]
                if mode in ("legacy-quit-success", "legacy-quit-declined")
                else [],
                "older": [201] if mode == "legacy-quit-success" else [],
                "owner": [150] if mode == "ldac-owner-running" else [],
            }
        )
    )
    return configs, state


def run(root, mode, name="Install.command", arguments=()):
    script = (
        (packaging / name)
        .read_text()
        .replace("/Applications", str(root / "Applications"))
        .replace("$HOME/Library/LaunchAgents", str(root / "LaunchAgents"))
        .replace("$HOME/Library/PreferencePanes", str(root / "PreferencePanes"))
        .replace("$HOME/Library/Caches", str(root / "Caches"))
    )
    script = re.sub(
        r"for attempt in \{1\.\.(?:20|80|120)\}", "for attempt in {1..4}", script
    )
    for original, stub in replacements.items():
        script = script.replace(original, str(root / "stubs" / stub))
    assert not any(original in script for original in replacements)
    assert "/Applications" not in script.replace(str(root / "Applications"), "")
    command = root / "package" / name
    command.write_text(script)
    env = {
        **os.environ,
        "PATH": str(root / "stubs") + ":" + os.environ["PATH"],
        "ACOUPLET_INSTALL_CHECK_ROOT": str(root),
        "ACOUPLET_INSTALL_CHECK_MODE": mode,
    }
    return subprocess.run(
        ["/bin/zsh", str(command), *arguments],
        check=False,
        env=env,
        text=True,
        capture_output=True,
        timeout=60,
    )


def check_private_install(scenario):
    with tempfile.TemporaryDirectory(prefix="acouplet-private-install-") as directory:
        root = Path(directory)
        fixture(root, "success")
        for parent in ("package", "Applications"):
            app = root / parent / "Acouplet.app"
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["AcoupletDistribution"] = "development"
            info["AcoupletSigningCertificateSHA1"] = "A" * 40
            if scenario == "production" and parent == "package":
                info["AcoupletDistribution"] = "production"
            info_path.write_bytes(plistlib.dumps(info))
            (app / "certificate").write_text(
                "B" * 40
                if scenario == "other-certificate" and parent == "Applications"
                else "A" * 40
            )
            (app / "team").write_text("not set")
        for legacy in ("XM5 Control Native.app", "XM5 Control.app"):
            (root / "Applications" / legacy / "certificate").write_text("A" * 40)
        result = run(
            root,
            "success",
            name="Uninstall Service.command"
            if scenario == "remove-service"
            else "Install.command",
        )
        assert (result.returncode == 0) == (scenario in ("update", "remove-service")), (
            result.stderr
        )
        if scenario == "remove-service":
            assert not (
                root / "LaunchAgents/dev.baglayan.Acouplet.agent.plist"
            ).exists()
        assert (root / "Applications/Acouplet.app/version").read_text() == (
            "new" if scenario == "update" else "old"
        )


for private_scenario in ("update", "other-certificate", "production", "remove-service"):
    checks.add("private/" + private_scenario, check_private_install, private_scenario)


def check_migration(scenario, mode, arguments, successful):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-team-migration-check-"
    ) as directory:
        root = Path(directory)
        configs, original_state = fixture(root, mode)
        applications = root / "Applications"
        for app in applications.glob("*.app"):
            if (app / "version").exists():
                (app / "team").write_text("OTHER12345")
        pane_info = {
            "CFBundleIdentifier": "dev.baglayan.Acouplet.preference-pane.001122334455",
            "SonyDeviceAddress": "00:11:22:33:44:55",
            "NSPrincipalClass": "SonyPreferencePane_001122334455",
        }
        for parent, version in (
            (root / "package/PreferencePanes", "new"),
            (root / "PreferencePanes", "old"),
        ):
            pane = parent / "Sony-001122334455.prefPane"
            (pane / "Contents").mkdir(parents=True)
            (pane / "Contents/Info.plist").write_bytes(plistlib.dumps(pane_info))
            (pane / "version").write_text(version)
            if version == "old":
                (pane / "team").write_text("OTHER12345")
        result = run(root, mode, arguments=arguments)
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == successful, (scenario, output)
        native = applications / "Acouplet.app"
        pane = root / "PreferencePanes/Sony-001122334455.prefPane"
        assert (native / "version").read_text() == ("new" if successful else "old"), (
            scenario,
            output,
        )
        assert (pane / "version").read_text() == ("new" if successful else "old"), (
            scenario,
            output,
        )
        commands = [
            json.loads(line)
            for line in (root / "commands.jsonl").read_text().splitlines()
        ]
        if successful:
            validations = [
                command
                for command in commands
                if command[:2] == ["codesign", "--verify"]
            ]
            assert any(
                'subject.OU] = "OTHER12345"' in " ".join(command)
                and command[-1] == str(native)
                for command in validations
            )
            assert any(
                'subject.OU] = "ABCDE12345"' in " ".join(command)
                and command[-1] == str(native)
                for command in validations
            )
        else:
            assert json.loads((root / "state.json").read_text()) == original_state, (
                scenario,
                output,
            )
            assert (
                root / "LaunchAgents" / (native_label + ".plist")
            ).read_bytes() == configs[native_label]
            if mode != "installed-validation-failure":
                assert not any(
                    command[0] in ("mv", "osascript") for command in commands
                ), (scenario, commands)
        assert not list(applications.glob(".*installing-*.app"))
        assert not [
            path
            for path in applications.glob(".*previous-*.app")
            if "interrupted" not in path.name
        ]


for scenario, mode, arguments, successful in (
    (
        "explicit-team-migration",
        "success",
        ("--require-stopped", "--replace-team", "OTHER12345"),
        True,
    ),
    ("team-migration-without-opt-in", "success", (), False),
    ("team-migration-wrong-pin", "success", ("--replace-team", "WRONG12345"), False),
    ("team-migration-invalid-pin", "success", ("--replace-team", "invalid"), False),
    ("team-migration-missing-pin", "success", ("--replace-team",), False),
    (
        "team-migration-bad-installed-signature",
        "installed-bad-signature",
        ("--replace-team", "OTHER12345"),
        False,
    ),
    (
        "team-migration-bad-source-signature",
        "source-bad-signature",
        ("--replace-team", "OTHER12345"),
        False,
    ),
    (
        "team-migration-rollback",
        "installed-validation-failure",
        ("--replace-team", "OTHER12345"),
        False,
    ),
):
    checks.add(
        "migration/" + scenario, check_migration, scenario, mode, arguments, successful
    )

scenarios = (
    "helper-failure",
    "success",
    "matching-plist",
    "previous-plist",
    "fresh-install",
    "inactive-update",
    "normal-running-update",
    "normal-stopped-update",
    "staging-failure",
    "launch-failure",
    "app-exits-on-launch",
    "stop-failure",
    "restore-app-failure",
    "restore-plist-failure",
    "move-new-failure",
    "restart-failure",
    "legacy-stop-failure",
    "legacy-running",
    "legacy-unregister-failure",
    "legacy-helper-failure",
    "legacy-bad-signature",
    "legacy-wrong-team",
    "installed-wrong-team",
    "legacy-quit-success",
    "legacy-quit-declined",
    "installed-bad-signature",
    "installed-validation-failure",
    "native-register-failure",
    "unexpected-bundle",
    "unexpected-agent",
    "unexpected-legacy-agent",
    "unexpected-loaded-service",
    "unexpected-loaded-legacy",
    "unrelated-legacy",
    "repurposed-legacy",
    "symlink-agent",
    "orphan-service",
    "concurrent-install",
    "native-quit-declined",
    "native-quit-timeout",
    "native-quit-stalled",
    "native-partial-quit",
    "native-keepalive-relaunch",
    "native-delayed-quit",
    "controls-unregister-failure",
    "embedded-controls",
    "foreign-controls",
    "ldac-owner-running",
)


def check_install(scenario):
    with tempfile.TemporaryDirectory(prefix="acouplet-install-check-") as directory:
        root = Path(directory)
        _configs, original_state = fixture(root, scenario)
        applications, agents = root / "Applications", root / "LaunchAgents"
        native = applications / "Acouplet.app"
        legacy = applications / "XM5 Control Native.app"
        plist = agents / (native_label + ".plist")
        before_plist = plist.read_bytes() if plist.exists() else None
        before_login = (root / "login-item.json").read_bytes()
        with (applications / ".Acouplet-install.lock").open("w") as lock:
            if scenario == "concurrent-install":
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = run(root, scenario)
        output = result.stdout + result.stderr
        commands = [
            json.loads(line)
            for line in (root / "commands.jsonl").read_text().splitlines()
        ]
        state = json.loads((root / "state.json").read_text())
        successful = scenario in (
            "success",
            "matching-plist",
            "previous-plist",
            "fresh-install",
            "inactive-update",
            "normal-running-update",
            "normal-stopped-update",
            "native-keepalive-relaunch",
            "native-delayed-quit",
            "legacy-quit-success",
            "ldac-owner-running",
        )
        committed_failure = scenario in (
            "legacy-unregister-failure",
            "legacy-helper-failure",
            "native-register-failure",
            "launch-failure",
            "app-exits-on-launch",
        )
        recovery_failure = scenario in (
            "restore-app-failure",
            "restore-plist-failure",
            "move-new-failure",
            "restart-failure",
            "stop-failure",
        )
        assert (result.returncode == 0) == successful, (scenario, output)
        assert not (root / "Caches/dev.baglayan.Acouplet/ldac-update-request").exists()
        assert (root / "login-item.json").read_bytes() == before_login
        assert ["Acouplet", "--register-login-item"] not in commands
        assert ["Acouplet", "--unregister-login-item"] not in commands
        recovery_apps = [
            path
            for path in applications.glob(".*previous-*.app")
            if "interrupted" not in path.name
        ]
        recovery_plists = [
            path
            for path in agents.glob("*.previous-*")
            if "interrupted" not in path.name
        ]
        staged_apps = list(applications.glob(".*installing-*.app"))
        if recovery_failure:
            assert bool(recovery_plists) == (scenario != "restart-failure"), (
                scenario,
                output,
            )
            assert bool(staged_apps) == (scenario != "move-new-failure"), (
                scenario,
                output,
            )
            assert "Recovery files were kept" in output
            if scenario == "restore-app-failure":
                assert not native.exists() and recovery_apps
            elif scenario == "move-new-failure":
                assert (native / "version").read_text() == "new" and recovery_apps
            else:
                assert (native / "version").read_text() == "old"
        else:
            assert not recovery_apps and not recovery_plists and not staged_apps, (
                scenario,
                output,
            )
            assert (native / "version").read_text() == (
                "new" if successful or committed_failure else "old"
            )
        if successful or committed_failure:
            assert not plist.exists() and not state[native_label]["loaded"], (
                scenario,
                state,
                output,
            )
            assert not any(
                command[:2] == ["launchctl", "bootstrap"] for command in commands
            )
            assert not any(
                command[:2] == ["launchctl", "kickstart"] for command in commands
            )
        elif not recovery_failure:
            assert state == original_state, (scenario, state, output)
            assert (plist.read_bytes() if plist.exists() else None) == before_plist
        if successful:
            should_launch = scenario not in ("inactive-update", "normal-stopped-update")
            assert (["open", str(native)] in commands) == should_launch, (
                scenario,
                commands,
            )
            assert ("installed and running (process 4242)" in output) == should_launch
            assert ("updated and remains stopped" in output) == (not should_launch)
            assert (
                not legacy.exists() and not (applications / "XM5 Control.app").exists()
            )
            assert all(not service["loaded"] for service in state.values())
            assert not (agents / (legacy_label + ".plist")).exists()
            assert ["lsregister", "-f", str(native)] in commands
            assert (root / "startup-preference-preserved").exists() == (
                before_plist is not None
            )
            if before_plist is not None:
                preserve_index = commands.index(
                    ["Acouplet", "--migrate-background-service-preferences"]
                )
                bootout_index = next(
                    index
                    for index, command in enumerate(commands)
                    if command[:2] == ["launchctl", "bootout"]
                )
                assert preserve_index < bootout_index
            if should_launch:
                assert commands.index(
                    ["lsregister", "-f", str(native)]
                ) < commands.index(["open", str(native)])
        if scenario == "helper-failure":
            assert "startup preference could not be preserved" in output
            assert not any(
                command[0] in ("mv", "osascript", "launchctl")
                and command[:2] != ["launchctl", "print"]
                for command in commands
            )
        if scenario in ("launch-failure", "app-exits-on-launch"):
            assert "installed and running" not in output
        if scenario in (
            "success",
            "native-delayed-quit",
            "native-quit-declined",
            "native-quit-stalled",
            "normal-running-update",
        ):
            assert (root / "handoff-requested").exists() == (
                scenario != "native-quit-declined"
            )
        if scenario.startswith("native-quit-") or scenario == "native-partial-quit":
            assert ["osascript", "-", "dev.baglayan.Acouplet"] in commands
            assert not any(
                command[:2] == ["launchctl", "bootout"] for command in commands
            )
            assert not any(command[0] == "mv" for command in commands)
            assert "Nothing was replaced" in output
            processes = json.loads((root / "processes.json").read_text())
            assert processes["native"] == (
                [101] if scenario == "native-partial-quit" else [100]
            )
        if scenario in (
            "success",
            "native-keepalive-relaunch",
            "native-delayed-quit",
            "ldac-owner-running",
        ):
            quit_index = commands.index(["osascript", "-", "dev.baglayan.Acouplet"])
            bootout_index = next(
                index
                for index, command in enumerate(commands)
                if command[:2] == ["launchctl", "bootout"]
                and command[2].endswith("/" + native_label)
            )
            assert quit_index < bootout_index
            exit_checks = [
                command
                for command in commands[quit_index + 1 : bootout_index]
                if command[0] == "kill"
            ]
            assert exit_checks and all(
                command == ["kill", "-0", "100"] for command in exit_checks
            )
            assert len(exit_checks) == (3 if scenario == "native-delayed-quit" else 1)
        if scenario == "legacy-quit-success":
            assert ["osascript", "-", "local.xm5control.native"] in commands
            assert ["osascript", "-", "local.xm5control"] in commands
            first_move = next(
                index for index, command in enumerate(commands) if command[0] == "mv"
            )
            assert commands.index(["kill", "-0", "200"]) < first_move
            assert commands.index(["kill", "-0", "201"]) < first_move
        controls = native / "Contents/PlugIns/Acouplet Controls.appex"
        unregistered = ["pluginkit", "-r", str(controls)] in commands
        reregistered = ["pluginkit", "-a", str(controls)] in commands
        if successful:
            assert not controls.exists()
            assert unregistered == (scenario != "fresh-install")
            assert not reregistered
        if scenario == "installed-validation-failure":
            assert controls.exists() and unregistered and reregistered
        if scenario in ("embedded-controls", "foreign-controls"):
            assert not unregistered and not reregistered
        for marker in root.rglob("keep"):
            assert marker.read_text() == "preserve"
        assert (
            root / "Preferences/dev.baglayan.Acouplet.plist"
        ).read_text() == "preserve"
        assert (agents / "unrelated.plist").read_text() == "preserve"
        assert (
            agents / (native_label + ".plist.previous-interrupted")
        ).read_text() == "preserve"
        if scenario == "concurrent-install":
            assert run(root, "success").returncode == 0


for scenario in scenarios:
    checks.add("install/" + str(scenario), check_install, scenario)


def check_uninstall(scenario):
    with tempfile.TemporaryDirectory(prefix="acouplet-uninstall-check-") as directory:
        root = Path(directory)
        configs, original_state = fixture(root, scenario)
        if scenario == "inactive-update":
            (root / "processes.json").write_text(
                json.dumps(
                    {
                        "native": [100],
                        "quit_requested": False,
                        "exit_checks": 0,
                        "legacy": [],
                        "older": [],
                    }
                )
            )
        result = run(root, scenario, "Uninstall Service.command")
        state = json.loads((root / "state.json").read_text())
        if scenario in (
            "success",
            "orphan-service",
            "inactive-update",
            "native-keepalive-relaunch",
            "native-delayed-quit",
            "legacy-quit-success",
        ):
            assert result.returncode == 0, result.stdout + result.stderr
            assert all(not service["loaded"] for service in state.values()), state
            assert not any(
                (root / "LaunchAgents" / (label + ".plist")).exists()
                for label in configs
            )
            assert run(root, scenario, "Uninstall Service.command").returncode == 0
        else:
            assert result.returncode != 0 and state == original_state, (
                result.stdout + result.stderr
            )
            assert all(
                (root / "LaunchAgents" / (label + ".plist")).exists()
                for label in configs
            )
        commands = [
            json.loads(line)
            for line in (root / "commands.jsonl").read_text().splitlines()
        ]
        if scenario.startswith("native-quit-") or scenario == "native-partial-quit":
            assert ["osascript", "-", "dev.baglayan.Acouplet"] in commands, commands
            assert not any(
                command[0] == "launchctl" and command[1] in ("bootout", "bootstrap")
                for command in commands
            ), commands
            assert "Nothing was removed" in result.stdout + result.stderr
        if scenario in (
            "success",
            "orphan-service",
            "native-keepalive-relaunch",
            "native-delayed-quit",
        ):
            quit_index = commands.index(["osascript", "-", "dev.baglayan.Acouplet"])
            bootout_index = next(
                index
                for index, command in enumerate(commands)
                if command[:2] == ["launchctl", "bootout"]
                and command[2].endswith("/" + native_label)
            )
            assert quit_index < bootout_index, commands
            checks = [
                command
                for command in commands[quit_index + 1 : bootout_index]
                if command[0] == "kill"
            ]
            assert len(checks) == (3 if scenario == "native-delayed-quit" else 1), (
                checks
            )
        if scenario == "inactive-update":
            assert ["osascript", "-", "dev.baglayan.Acouplet"] in commands, commands
            assert json.loads((root / "processes.json").read_text())["native"] == []
        assert (root / "Applications/Acouplet.app/version").read_text() == "old"
        assert (
            root / "Applications/XM5 Control Native.app/version"
        ).read_text() == "legacy"
        assert (
            root / "Preferences/dev.baglayan.Acouplet.plist"
        ).read_text() == "preserve"


for scenario in (
    "success",
    "orphan-service",
    "unexpected-agent",
    "unexpected-loaded-legacy",
    "unexpected-bundle",
    "repurposed-legacy",
    "stop-failure",
    "inactive-update",
    "native-quit-declined",
    "native-quit-timeout",
    "native-quit-stalled",
    "native-partial-quit",
    "native-keepalive-relaunch",
    "native-delayed-quit",
    "legacy-quit-success",
    "legacy-quit-declined",
    "legacy-wrong-team",
):
    checks.add("uninstall/" + str(scenario), check_uninstall, scenario)


def check_local(scenario):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-local-install-check-"
    ) as directory:
        root = Path(directory)
        mode = "success" if scenario.startswith("running") else "inactive-update"
        _, initial_state = fixture(root, mode)
        source = root / "package/Acouplet.app"
        binaries = (
            "Contents/MacOS/Acouplet",
            "Contents/Helpers/Acouplet Battery Publisher",
            "Contents/Frameworks/SonyNativeHUD.dylib",
            "Contents/Helpers/SonyNativeHUDCheck",
            "Contents/Resources/Assets.car",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
            "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
            "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "Contents/Helpers/LDACSignaling",
            "Contents/Helpers/LDACMediaTransport",
            "Contents/Helpers/SonyAudioConnection",
            "Contents/Helpers/LDACLogObserver",
            "Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio",
            "Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput",
            "Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist",
            "Contents/Resources/Acouplet LDAC Output.pkg",
            "Contents/Resources/Acouplet LDAC Removal.pkg",
            "Contents/_CodeSignature/CodeResources",
        )
        for relative in binaries[1:]:
            binary = source / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text(relative)
        release = root / "Release.app"
        shutil.copytree(source, release)
        lines = [
            "Prepared UTC: 2026-09-27T00:00:00Z",
            "Revision: fixture",
            "Worktree: dirty",
            "Release app: " + str(release),
        ]
        lines += [
            "SHA256\t"
            + hashlib.sha256((source / relative).read_bytes()).hexdigest()
            + "\t"
            + relative
            for relative in binaries
        ]
        (root / "package/Local Build Receipt.txt").write_text("\n".join(lines) + "\n")
        if scenario in ("local-release-changed", "running-release-changed"):
            (release / binaries[0]).write_text("later build")
        if scenario == "local-stage-changed":
            (source / binaries[1]).write_text("changed stage")
        if scenario == "local-hud-check-changed":
            (source / "Contents/Helpers/SonyNativeHUDCheck").write_text("changed probe")
        if scenario == "local-ldac-media-changed":
            (source / "Contents/Helpers/LDACMediaTransport").write_text(
                "changed encoder"
            )
        if scenario == "local-audio-capture-changed":
            (
                release
                / "Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio"
            ).write_text("changed capture")
        if scenario == "local-output-driver-changed":
            (
                source
                / "Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput"
            ).write_text("changed driver")
        if scenario == "local-output-driver-info-changed":
            (
                release
                / "Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist"
            ).write_text("changed driver metadata")
        if scenario == "local-driver-installer-changed":
            (source / "Contents/Resources/Acouplet LDAC Output.pkg").write_text(
                "changed installer"
            )
        if scenario == "local-driver-uninstaller-changed":
            (source / "Contents/Resources/Acouplet LDAC Removal.pkg").write_text(
                "changed uninstaller"
            )
        if scenario == "local-resource-seal-changed":
            (source / "Contents/_CodeSignature/CodeResources").write_text(
                "changed resource seal"
            )
        result = run(root, mode, arguments=("--require-stopped",))
        commands = [
            json.loads(line)
            for line in (root / "commands.jsonl").read_text().splitlines()
        ]
        # The local-build mode quits the running app itself, but only once the receipt has been verified.
        assert any(command[0] == "osascript" for command in commands) == (
            scenario == "running"
        ), commands
        receipts = list(root.glob("Local Install-*.txt"))
        installed = root / "Applications/Acouplet.app"
        if scenario in ("local-stopped", "running"):
            assert result.returncode == 0, result.stdout + result.stderr
            assert len(receipts) == 1
            assert (
                "Release/staged/installed identity and strict signature verification: passed"
                in receipts[0].read_text()
            )
            assert "Installed UTC:" in receipts[0].read_text()
            for relative in binaries:
                assert (installed / relative).read_bytes() == (
                    release / relative
                ).read_bytes()
            assert not json.loads((root / "state.json").read_text())[native_label][
                "loaded"
            ]
        else:
            assert result.returncode != 0, result.stdout + result.stderr
            assert not receipts
            assert (installed / "version").read_text() == "old"
            assert json.loads((root / "state.json").read_text()) == initial_state
        assert (
            root / "Preferences/dev.baglayan.Acouplet.plist"
        ).read_text() == "preserve"


for scenario in (
    "running",
    "running-release-changed",
    "local-stopped",
    "local-release-changed",
    "local-stage-changed",
    "local-hud-check-changed",
    "local-ldac-media-changed",
    "local-audio-capture-changed",
    "local-output-driver-changed",
    "local-output-driver-info-changed",
    "local-driver-installer-changed",
    "local-driver-uninstaller-changed",
    "local-resource-seal-changed",
):
    checks.add("local/" + str(scenario), check_local, scenario)


def check_driver_message(driver_state, message):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-driver-message-check-"
    ) as directory:
        root = Path(directory)
        fixture(root, "success")
        driver_installer = (
            root / "package/Acouplet.app/Contents/Resources/Acouplet LDAC Output.pkg"
        )
        driver_installer.parent.mkdir(parents=True)
        driver_installer.write_text("fixture")
        (root / "driver-state").write_text(driver_state)
        result = run(root, "success")
        assert result.returncode == 0, result.stdout + result.stderr
        assert message in result.stdout, (driver_state, result.stdout)
        assert ("restart the mac" in result.stdout.lower()) == (
            driver_state not in ("current", "unavailable", "fail")
        ), result.stdout
        assert ("did not install the driver" in result.stdout) == (
            driver_state != "current"
        ), result.stdout


for driver_state, message in (
    ("current", "already up to date; no restart is needed"),
    (
        "restartRequired",
        "The LDAC audio driver is installed. Restart the Mac to activate it.",
    ),
    (
        "outdated",
        "includes a newer LDAC audio driver. Use Update LDAC Driver in the app",
    ),
    ("missing", "turn it on in the app to install its audio driver"),
    ("unavailable", "could not be checked"),
    ("fail", "could not be checked"),
):
    checks.add(
        "driver-message/" + driver_state, check_driver_message, driver_state, message
    )


def check_pane(scenario):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-pane-install-check-"
    ) as directory:
        root = Path(directory)
        fixture(root, "inactive-update")
        panes = root / "PreferencePanes"
        panes.mkdir()
        for suffix in ("001122334455", "001122334466"):
            info = {
                "CFBundleIdentifier": "dev.baglayan.Acouplet.preference-pane."
                + suffix.lower(),
                "SonyDeviceAddress": ":".join(
                    suffix[i : i + 2] for i in range(0, 12, 2)
                ),
                "NSPrincipalClass": "SonyPreferencePane_" + suffix,
            }
            for parent, version in (
                (root / "package/PreferencePanes", "new"),
                (panes, "old"),
            ):
                pane = parent / ("Sony-" + suffix + ".prefPane")
                (pane / "Contents").mkdir(parents=True)
                (pane / "Contents/Info.plist").write_bytes(
                    plistlib.dumps(
                        {
                            **info,
                            "CFBundleIdentifier": "local.xm5control.native.preference-pane."
                            + suffix.lower(),
                        }
                        if scenario == "pane-legacy-target" and version == "old"
                        else info
                    )
                )
                (pane / "version").write_text(version)
        prototype = panes / "Sony Headphones Compatibility.prefPane"
        (prototype / "Contents").mkdir(parents=True)
        prototype_id = (
            "unrelated"
            if scenario == "pane-foreign-prototype"
            else "dev.baglayan.Acouplet.research.preference-pane"
        )
        (prototype / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": prototype_id})
        )
        (panes / "Other.prefPane").mkdir()
        first = panes / "Sony-001122334455.prefPane"
        second = panes / "Sony-001122334466.prefPane"
        if scenario == "pane-foreign-target":
            (second / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "unrelated"})
            )
        if scenario == "pane-symlink-target":
            shutil.rmtree(second)
            second.symlink_to(panes / "Other.prefPane", target_is_directory=True)
        result = run(root, scenario)
        succeeded = scenario in (
            "pane-success",
            "pane-legacy-target",
            "pane-foreign-prototype",
        )
        assert (result.returncode == 0) == succeeded, (
            scenario,
            result.stdout,
            result.stderr,
        )
        app = root / "Applications/Acouplet.app"
        if succeeded:
            assert (app / "version").read_text() == "new"
            assert (
                (first / "version").read_text()
                == (second / "version").read_text()
                == "new"
            )
            assert prototype.exists() == (scenario == "pane-foreign-prototype")
        elif scenario == "pane-commit-failure":
            assert (app / "version").read_text() == "new"
            assert (first / "version").read_text() == "new" and (
                second / "version"
            ).read_text() == "old"
            assert prototype.exists()
            assert "could not all be installed" in result.stderr
        else:
            assert (
                (app / "version").read_text()
                == (first / "version").read_text()
                == "old"
            )
            assert prototype.exists()
        assert (panes / "Other.prefPane").is_dir()
        assert not list(panes.glob(".*.installing-*")) and not list(
            panes.glob(".*.previous-*")
        )
        assert not json.loads((root / "state.json").read_text())[native_label]["loaded"]


for scenario in (
    "pane-success",
    "pane-legacy-target",
    "pane-foreign-target",
    "pane-symlink-target",
    "pane-bad-signature",
    "pane-stage-failure",
    "pane-commit-failure",
    "pane-foreign-prototype",
):
    checks.add("pane/" + str(scenario), check_pane, scenario)


def check_legacy(scenario):
    with tempfile.TemporaryDirectory(
        prefix="acouplet-legacy-install-check-"
    ) as directory:
        root = Path(directory)
        fixture(root, "success")
        controls = (
            root
            / "Applications/XM5 Control Native.app/Contents/PlugIns/XM5 Controls.appex"
        )
        (controls / "Contents").mkdir(parents=True)
        (controls / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "unrelated"
                    if scenario == "foreign-legacy-controls"
                    else "local.xm5control.native.controls"
                }
            )
        )
        with (root / "Applications/.XM5-Control-install.lock").open("w") as lock:
            if scenario == "concurrent-legacy-install":
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = run(root, "success")
        assert (result.returncode == 0) == (scenario == "legacy-controls"), (
            scenario,
            result.stdout,
            result.stderr,
        )
        commands = [
            json.loads(line)
            for line in (root / "commands.jsonl").read_text().splitlines()
        ]
        assert (["pluginkit", "-r", str(controls)] in commands) == (
            scenario == "legacy-controls"
        ), commands
        assert (root / "Applications/Acouplet.app/version").read_text() == (
            "new" if scenario == "legacy-controls" else "old"
        )


for scenario in (
    "legacy-controls",
    "foreign-legacy-controls",
    "concurrent-legacy-install",
):
    checks.add("legacy/" + str(scenario), check_legacy, scenario)


if __name__ == "__main__":
    checks.main()
