import argparse
import hashlib
import json
import os
import plistlib
import re
import runpy
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

DEVELOPER_ID = "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
sparkle = runpy.run_path(str(Path(__file__).with_name("check-sparkle-bundle.py")))


def command(args):
    try:
        result = subprocess.run(args, check=False, capture_output=True, timeout=30)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, b"", b"Check timed out; result is unverified."


def inspect_code(path, team=None, executable=True):
    verify, _, _ = command(
        [
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--all-architectures",
            str(path),
        ]
    )
    developer_id, _, _ = command(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--test-requirement=" + DEVELOPER_ID,
            str(path),
        ]
    )
    display, _, signature_bytes = command(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(path)]
    )
    signature = signature_bytes.decode(errors="replace")
    entitlement_status, entitlement_bytes, _ = command(
        ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(path)]
    )
    entitlements = None
    if entitlement_status == 0:
        try:
            entitlements = (
                plistlib.loads(entitlement_bytes) if entitlement_bytes.strip() else {}
            )
        except plistlib.InvalidFileException:
            pass
    checks = {
        "strict_nested_signatures": verify == 0,
        "developer_id_application": developer_id == 0,
        "secure_timestamp": display == 0
        and bool(re.search(r"^Timestamp=.+$", signature, re.MULTILINE)),
        "same_signing_team": bool(team)
        and display == 0
        and "TeamIdentifier=" + team in signature.splitlines(),
    }
    if executable:
        checks["hardened_runtime"] = display == 0 and bool(
            re.search(
                r"^CodeDirectory .*flags=.*\b runtime\b",
                signature,
                re.MULTILINE | re.VERBOSE,
            )
        )
        checks["debugger_entitlement_absent"] = isinstance(
            entitlements, dict
        ) and not bool(entitlements.get("com.apple.security.get-task-allow", False))
        if path.name in ("Acouplet.app", "Acouplet Battery Publisher"):
            expected = {}
            if path.name == "Acouplet.app":
                expected.update(
                    {
                        "com.apple.security.device.bluetooth": True,
                        "com.apple.security.network.client": True,
                    }
                )
            checks["security_entitlements_preserved"] = (
                isinstance(entitlements, dict)
                and {
                    key: value
                    for key, value in entitlements.items()
                    if key.startswith("com.apple.security.")
                }
                == expected
            )
    return checks


def bundle_files(directory):
    return {
        str(path.relative_to(directory)): ("link", os.readlink(path))
        if path.is_symlink()
        else (
            "file",
            hashlib.sha256(path.read_bytes()).hexdigest(),
            stat.S_IMODE(path.stat().st_mode),
        )
        if path.is_file()
        else ("directory", stat.S_IMODE(path.stat().st_mode))
        for path in directory.rglob("*")
    }


def inspect_installer(app, team, removal=False):
    installer = (
        app
        / "Contents/Resources"
        / ("Acouplet LDAC Removal.pkg" if removal else "Acouplet LDAC Output.pkg")
    )
    checks = {"embedded_installer": installer.is_file() and not installer.is_symlink()}
    if not checks["embedded_installer"]:
        return checks
    status, stdout, stderr = command(
        ["/usr/sbin/pkgutil", "--check-signature", str(installer)]
    )
    signature = (stdout + stderr).decode(errors="replace")
    match = re.search(
        r"^\s*1\. Developer ID Installer: .+ \(([A-Z0-9]{10})\)\s*$",
        signature,
        re.MULTILINE,
    )
    checks["developer_id_installer"] = status == 0 and bool(match)
    checks["same_signing_team"] = bool(team) and bool(match) and match[1] == team
    checks["secure_timestamp"] = (
        status == 0 and "Signed with a trusted timestamp on:" in signature
    )
    with tempfile.TemporaryDirectory(
        prefix="acouplet-driver-payload-check-"
    ) as directory:
        expanded = Path(directory) / "expanded"
        status, _, _ = command(
            ["/usr/sbin/pkgutil", "--expand-full", str(installer), str(expanded)]
        )
        checks["payload_expanded"] = status == 0
        if status != 0:
            return checks
        try:
            info = ET.parse(expanded / "PackageInfo").getroot()
            app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if removal:
                checks["package_identity"] = (
                    info.get("identifier") == "dev.baglayan.Acouplet.LDACOutput.Removal"
                )
                checks["package_version"] = (
                    info.get("version") == app_info["CFBundleShortVersionString"]
                )
                payload = expanded / "Payload"
                checks["no_payload"] = not payload.is_symlink() and (
                    not payload.exists()
                    or (payload.is_dir() and not list(payload.iterdir()))
                )
                checks["no_bundles"] = not info.findall("bundle")
                script = (
                    Path(__file__).with_name("LDACOutputUninstaller") / "postinstall"
                )
                expected_scripts = (
                    {
                        "postinstall": (
                            "file",
                            hashlib.sha256(
                                script.read_bytes()
                                .replace(
                                    b"@ACOUPLET_LDAC_SIGNING_CERTIFICATE_SHA1@", b""
                                )
                                .replace(
                                    b"@ACOUPLET_LDAC_SIGNING_TEAM_ID@", team.encode()
                                )
                            ).hexdigest(),
                            0o755,
                        )
                    }
                    if team
                    else {}
                )
                checks["installer_scripts"] = (
                    bool(team)
                    and bundle_files(expanded / "Scripts") == expected_scripts
                )
                checks["installer_script_entries"] = [
                    (entry.tag, entry.get("file"))
                    for entry in info.findall("scripts/*")
                ] == [("postinstall", "./postinstall")]
                return checks
            driver = app / "Contents/Helpers/AcoupletLDACOutput.driver"
            payload = expanded / "Payload/AcoupletLDACOutput.driver"
            driver_info = plistlib.loads((driver / "Contents/Info.plist").read_bytes())
            bundle = info.find("bundle")
            checks["package_identity"] = (
                info.get("identifier") == "dev.baglayan.Acouplet.LDACOutput"
            )
            checks["package_version"] = (
                info.get("version") == app_info["CFBundleShortVersionString"]
            )
            checks["install_location"] = (
                info.get("install-location") == "/Library/Audio/Plug-Ins/HAL"
            )
            checks["driver_identity"] = (
                driver_info.get("CFBundleIdentifier")
                == "dev.baglayan.Acouplet.LDACOutput"
            )
            checks["driver_build"] = (
                driver_info.get("CFBundleVersion") == app_info["CFBundleVersion"]
            )
            checks["package_bundle_metadata"] = (
                bundle is not None
                and bundle.get("path") == "./AcoupletLDACOutput.driver"
                and bundle.get("id") == driver_info["CFBundleIdentifier"]
                and bundle.get("CFBundleVersion") == driver_info["CFBundleVersion"]
            )
            checks["driver_only_payload"] = sorted(
                path.name for path in (expanded / "Payload").iterdir()
            ) == ["AcoupletLDACOutput.driver"]
            checks["payload_matches_embedded_driver"] = (
                payload.is_dir()
                and not payload.is_symlink()
                and bundle_files(payload) == bundle_files(driver)
            )
            scripts = Path(__file__).with_name("LDACOutputInstaller")
            expected_scripts = (
                {
                    name: (
                        "file",
                        hashlib.sha256(
                            (scripts / name)
                            .read_bytes()
                            .replace(b"@ACOUPLET_LDAC_SIGNING_TEAM_ID@", team.encode())
                            .replace(b"@ACOUPLET_LDAC_SIGNING_CERTIFICATE_SHA1@", b"")
                        ).hexdigest(),
                        0o755,
                    )
                    for name in ("preinstall", "postinstall")
                }
                if team
                else {}
            )
            checks["installer_scripts"] = (
                bool(team) and bundle_files(expanded / "Scripts") == expected_scripts
            )
            checks["installer_script_entries"] = [
                (entry.tag, entry.get("file")) for entry in info.findall("scripts/*")
            ] == [("preinstall", "./preinstall"), ("postinstall", "./postinstall")]
            checks.update(
                {
                    "driver_" + key: passed
                    for key, passed in inspect_code(payload, team).items()
                }
            )
        except (OSError, ValueError, KeyError, ET.ParseError):
            checks["payload_metadata"] = False
    return checks


def inspect_package(package, signatures_only=False, dmg=None):
    app = package / "Acouplet.app"
    panes = sorted((package / "PreferencePanes").glob("*.prefPane"))
    _, _, signature = command(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(app)]
    )
    match = re.search(
        r"^TeamIdentifier=([A-Z0-9]{10})$",
        signature.decode(errors="replace"),
        re.MULTILINE,
    )
    team = match[1] if match else None
    targets = [
        app,
        app / "Contents/Helpers/Acouplet Battery Publisher",
        app / "Contents/Frameworks/SonyNativeHUD.dylib",
        app / "Contents/Helpers/SonyNativeHUDCheck",
        *sparkle["code_targets"](app),
        *[
            app / "Contents/Helpers" / name
            for name in [
                "LDACSignaling",
                "LDACMediaTransport",
                "SonyAudioConnection",
                "LDACLogObserver",
                "Acouplet Audio.app",
                "AcoupletLDACOutput.driver",
            ]
        ],
        *panes,
    ]
    code = {
        str(path.relative_to(package)): inspect_code(path, team) for path in targets
    }
    installer = inspect_installer(app, team)
    uninstaller = inspect_installer(app, team, removal=True)
    if dmg:
        code[str(dmg)] = inspect_code(dmg, team, executable=False)
    staples = {}
    staple_targets = (
        []
        if signatures_only
        else [
            app / "Contents/Resources/Acouplet LDAC Output.pkg",
            app / "Contents/Resources/Acouplet LDAC Removal.pkg",
            *([dmg] if dmg else [app, *panes]),
        ]
    )
    for path in staple_targets:
        status, stdout, stderr = command(
            ["/usr/bin/xcrun", "stapler", "validate", str(path)]
        )
        message = (stdout + stderr).decode(errors="replace")
        name = str(path) if path == dmg else str(path.relative_to(package))
        staples[name] = {
            "verified": status == 0,
            "status": "valid"
            if status == 0
            else "missing"
            if "does not have a ticket stapled to it" in message
            else "unverified",
            "exit_code": status,
        }
    controls = app / "Contents/PlugIns/Acouplet Controls.appex"
    blockers = [
        name + ": " + check
        for name, checks in code.items()
        for check, passed in checks.items()
        if not passed
    ]
    blockers += [
        "Embedded LDAC installer: " + check
        for check, passed in installer.items()
        if not passed
    ]
    blockers += [
        "Embedded LDAC uninstaller: " + check
        for check, passed in uninstaller.items()
        if not passed
    ]
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("AcoupletDistribution") != "production":
            blockers.append("Website release must declare production distribution")
        sparkle["check_bundle"](app)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        blockers.append("Sparkle integration: " + str(error))
    if controls.exists():
        blockers.append("Deferred Control Center extension is embedded")
    blockers += [
        name + ": stapled ticket " + check["status"]
        for name, check in staples.items()
        if not check["verified"]
    ]
    return {
        "checked_utc": datetime.now(timezone.utc).isoformat(),
        "package": str(package),
        "scope": "App, battery helper, native HUD, Sparkle framework and nested tools, LDAC transport/audio helpers, HAL driver and embedded installer/uninstaller, separately packaged panes and optional DMG. No notarization upload or installed-app modification.",
        "signing_team": team,
        "signing_prerequisites_pass": all(
            all(checks.values()) for checks in code.values()
        )
        and all(installer.values())
        and all(uninstaller.values()),
        "stapled_tickets_verified": bool(staples)
        and all(check["verified"] for check in staples.values()),
        "code": code,
        "installer": installer,
        "uninstaller": uninstaller,
        "staples": staples,
        "blockers": blockers,
        "limits": "A missing staple does not prove absence of server-side notarization. Stapler validation may contact Apple’s ticket service. This is not App Review, Apple accessory certification, or a clean-machine Gatekeeper test.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    parser.add_argument("--signatures-only", action="store_true")
    parser.add_argument("--dmg", type=Path)
    args = parser.parse_args()
    if not args.package.is_dir() or (args.dmg and not args.dmg.is_file()):
        parser.error(
            "Supply an existing package directory and, when requested, DMG file."
        )
    report = inspect_package(
        args.package.resolve(),
        args.signatures_only,
        args.dmg.resolve() if args.dmg else None,
    )
    print(json.dumps(report, indent=2))
    sys.exit(1 if report["blockers"] else 0)
