import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
encoder = root / "Vendor/libldac"
with tempfile.TemporaryDirectory(prefix="acouplet-logfree-transports-") as directory:
    for source, arguments in (
        ("LDACLogFreeSignalingTests.m", []),
        (
            "LDACLogFreeMediaTests.m",
            [
                "-I",
                encoder / "inc",
                "-I",
                encoder / "src",
                encoder / "src/ldacBT.c",
                encoder / "src/ldaclib.c",
            ],
        ),
    ):
        binary = Path(directory) / Path(source).stem
        subprocess.run(
            [
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "clang",
                "-fobjc-arc",
                "-fblocks",
                "-Werror",
                "-D_DARWIN_C_SOURCE",
                "-DACOUPLET_LDAC_PROBE_ONLY=0",
                "-mmacosx-version-min=15.4",
                "-framework",
                "Foundation",
                "-framework",
                "CoreFoundation",
                "-framework",
                "CoreBluetooth",
                "-framework",
                "IOBluetooth",
                root / "Helpers/LDAC" / source,
                *arguments,
                "-o",
                binary,
            ],
            check=True,
        )
        subprocess.run([binary], check=True)
