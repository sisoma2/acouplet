import sys
from pathlib import Path
from tempfile import TemporaryDirectory


class StubExecutable:
    def __init__(self, source):
        self.directory = TemporaryDirectory(prefix="acouplet-check-stub-")
        self.path = Path(self.directory.name) / "stub"
        if source.startswith("#!/usr/bin/python3\n"):
            source = "#!" + sys.executable + "\n" + source.split("\n", 1)[1]
        self.path.write_text(source)
        self.path.chmod(0o755)

    def link(self, path):
        path.symlink_to(self.path)

    def close(self):
        self.directory.cleanup()
