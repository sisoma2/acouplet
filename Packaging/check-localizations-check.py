import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path

packaging = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "localizations", packaging / "check-localizations.py"
)
localizations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localizations)
catalog = localizations.check_catalog(packaging.parent)

with tempfile.TemporaryDirectory(prefix="acouplet-localization-check-") as directory:
    root = Path(directory)
    source = root / "Interpolated Status.swift"
    source.write_text(r"""import Foundation
func status(rate: Int, bitrate: Int, channels: Int) -> String {
    String(localized: "\((Double(rate) / 1_000).formatted()) kHz · \(bitrate) kb/s")
        + String(localized: " · \(channels) channels")
}
""")
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            "-c",
            "-emit-localized-strings",
            "-emit-localized-strings-path",
            str(root),
            str(source),
            "-o",
            str(root / "status.o"),
        ],
        check=True,
    )
    file_list = root / "Acouplet.SwiftFileList"
    file_list.write_text('"' + str(source) + '"\n')
    localizations.check_extraction(root, catalog)
    missing_key = "%@ kHz · %lld kb/s"
    incomplete = {
        "strings": {
            key: value
            for key, value in catalog["strings"].items()
            if key != missing_key
        }
    }
    try:
        localizations.check_extraction(root, incomplete)
    except AssertionError as error:
        assert missing_key in str(error)
    else:
        raise AssertionError("Missing compiler-extracted interpolation passed")
    second = root / "Unextracted.swift"
    second.write_text("func value() -> Int { 1 }\n")
    file_list.write_text('"' + str(source) + '"\n"' + str(second) + '"\n')
    try:
        localizations.check_extraction(root, catalog)
    except AssertionError as error:
        assert str(second) in str(error)
    else:
        raise AssertionError("Partial compiler extraction passed")
    metadata = root / "metadata-only"
    metadata.mkdir()
    (metadata / "Acouplet.SwiftFileList").write_text('"' + str(source) + '"\n')
    (metadata / "ExtractedAppShortcutsMetadata.stringsdata").write_text(
        json.dumps(
            {
                "source": "ExtractedAppShortcutsMetadata",
                "tables": {},
                "version": 2,
            }
        )
    )
    try:
        localizations.check_extraction(metadata, catalog)
    except AssertionError as error:
        assert str(source) in str(error)
    else:
        raise AssertionError(
            "AppShortcuts metadata alone passed compiler string coverage"
        )
print(
    "Native interpolation, missing-key, partial-extraction and metadata-only checks: passed"
)
