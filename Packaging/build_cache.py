import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

build_settings = (
    "DEVELOPER_DIR",
    "SDKROOT",
    "SDK_VERSION",
    "SDK_PRODUCT_BUILD_VERSION",
    "CONFIGURATION",
    "ARCHS",
    "MACOSX_DEPLOYMENT_TARGET",
    "SWIFT_VERSION",
    "SWIFT_OPTIMIZATION_LEVEL",
    "CODE_SIGNING_ALLOWED",
    "EXPANDED_CODE_SIGN_IDENTITY",
    "EXPANDED_CODE_SIGN_IDENTITY_NAME",
    "PATH",
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "LIBRARY_PATH",
    "TOOLCHAINS",
)


def fingerprint(path):
    path = Path(path)
    if path.is_symlink():
        return ["link", os.readlink(path), fingerprint(path.resolve())]
    if path.is_file():
        return [
            stat.S_IMODE(path.stat().st_mode),
            hashlib.sha256(path.read_bytes()).hexdigest(),
        ]
    if path.is_dir():
        return {
            child.name: fingerprint(child)
            for child in sorted(path.iterdir())
            if child.name not in ("__pycache__", ".DS_Store")
        }
    return None


def run_cached(command, inputs, outputs, cache, restore=False):
    command = list(map(str, command))
    if os.environ.get("ACOUPLET_BUILD_CACHE") == "NO":
        subprocess.run(command, check=True)
        return
    outputs = list(map(Path, outputs))
    cache = Path(cache)
    inputs = [*map(Path, inputs), Path(__file__)]
    sdk = os.environ.get("SDKROOT")
    developer = os.environ.get("DEVELOPER_DIR")
    if not developer and sdk:
        developer = next(
            (str(parent) for parent in Path(sdk).parents if parent.name == "Developer"),
            None,
        )
    if developer:
        inputs.extend(
            (
                Path(developer).parent / "version.plist",
                Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
            )
        )
    if sdk:
        inputs.append(Path(sdk) / "SDKSettings.json")
    state = {
        "command": command,
        "cwd": os.getcwd(),
        "outputs": list(map(str, outputs)),
        "environment": {name: os.environ.get(name) for name in build_settings},
        "inputs": {str(path): fingerprint(path) for path in inputs},
    }
    key = hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()
    record = cache / "record.json"
    try:
        saved = json.loads(record.read_text())
    except (OSError, ValueError):
        saved = {}
    if not isinstance(saved, dict):
        saved = {}
    if saved.get("key") == key and len(saved.get("outputs", [])) == len(outputs):
        if all(
            fingerprint(output) == expected
            for output, expected in zip(outputs, saved["outputs"])
        ):
            print("Reusing build: " + outputs[0].name, flush=True)
            return
        if restore and all(
            fingerprint(cache / str(index)) == expected
            for index, expected in enumerate(saved["outputs"])
        ):
            for index, output in enumerate(outputs):
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(cache / str(index), output)
            print("Restoring build: " + outputs[0].name, flush=True)
            return
    record.unlink(missing_ok=True)
    subprocess.run(command, check=True)
    result = [fingerprint(output) for output in outputs]
    if any(value is None for value in result):
        raise ValueError("Build did not produce all declared outputs: " + str(outputs))
    cache.mkdir(parents=True, exist_ok=True)
    if restore:
        for index, output in enumerate(outputs):
            shutil.copy2(output, cache / str(index))
    with tempfile.NamedTemporaryFile(mode="w", dir=cache, delete=False) as temporary:
        json.dump({"key": key, "outputs": result}, temporary)
    os.replace(temporary.name, record)


def main():
    parser = argparse.ArgumentParser(
        description="Reuse unchanged native build outputs; checks still execute on every run."
    )
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--input", action="append", default=[], type=Path)
    parser.add_argument("--output", action="append", default=[], type=Path)
    parser.add_argument("--compiler", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("A build command is required")
    if options.compiler:
        options.output = [Path(command[command.index("-o") + 1])]
        options.cache /= options.output[0].name
        for argument in command:
            if argument == str(options.output[0]):
                continue
            if argument.startswith("-Wl,-sectcreate,"):
                options.input.append(Path(argument.rsplit(",", 1)[-1]))
            elif Path(argument).is_file():
                options.input.append(Path(argument))
    if not options.output:
        parser.error("Declare at least one output")
    run_cached(
        command, options.input, options.output, options.cache, restore=options.compiler
    )


if __name__ == "__main__":
    main()
