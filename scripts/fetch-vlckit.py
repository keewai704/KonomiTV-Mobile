#!/usr/bin/env python3
"""Fetches the iOS slices of VLCKit 4 into Vendor/VLCKit.xcframework.

VideoLAN publishes VLCKit as one ~865 MB zip holding every Apple platform
plus dSYMs. Only the iOS device and simulator frameworks (~65 MB compressed)
are needed, so this reads the zip's central directory with HTTP range
requests and downloads just those members. Each member is checked against
its zip CRC, and each binary against the SHA-256 pinned below.

Usage: scripts/fetch-vlckit.py [output.xcframework]
"""

import hashlib
import io
import os
import plistlib
import shutil
import sys
import urllib.request
import zipfile

VERSION = "4.0.0-a22"
URL = "https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260720-1538.zip"
SLICES = ["ios-arm64", "ios-arm64_x86_64-simulator"]
BINARY_SHA256 = {
    "ios-arm64": "127fbe4fc07f77c7d45ee6816f66dd9a6c88c60d50e0e340acaab2654fa740e5",
    "ios-arm64_x86_64-simulator": "759159e52406cfdea662676ce8f2213875b84429bd98556eb06915295de07254",
}
PREFIX = "VLCKit.xcframework/"
STAMP = ".konomitv-vlckit-version"


class HTTPRangeFile(io.RawIOBase):
    """A seekable read-only file over HTTP range requests."""

    def __init__(self, url):
        super().__init__()
        self.url = url
        self.pos = 0
        head = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(head, timeout=60) as response:
            self.size = int(response.headers["Content-Length"])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=io.SEEK_SET):
        if whence == io.SEEK_SET:
            self.pos = offset
        elif whence == io.SEEK_CUR:
            self.pos += offset
        else:
            self.pos = self.size + offset
        return self.pos

    def readinto(self, buffer):
        if self.pos >= self.size:
            return 0
        end = min(self.pos + len(buffer), self.size) - 1
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 206:
                        raise OSError(f"range request returned HTTP {response.status}")
                    data = response.read()
                break
            except OSError:
                if attempt == 4:
                    raise
        buffer[: len(data)] = data
        self.pos += len(data)
        return len(data)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Vendor", "VLCKit.xcframework"))
    stamp = os.path.join(output, STAMP)
    if os.path.exists(stamp) and open(stamp).read().strip() == VERSION:
        print(f"VLCKit {VERSION} is already at {output}")
        return

    staging = output + ".partial"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)

    # A large read buffer keeps the number of range requests low.
    archive = zipfile.ZipFile(io.BufferedReader(HTTPRangeFile(URL), buffer_size=8 << 20))
    wanted = [
        info for info in archive.infolist()
        if any(info.filename.startswith(f"{PREFIX}{slice}/VLCKit.framework/") for slice in SLICES)
    ]
    if not wanted:
        sys.exit("VLCKit archive has none of the expected iOS slices")
    for info in wanted:
        relative = info.filename[len(PREFIX):]
        destination = os.path.join(staging, relative)
        if info.is_dir():
            os.makedirs(destination, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        if info.compress_size > 1 << 20:
            print(f"  {relative} ({info.compress_size / 1e6:.1f} MB)", flush=True)
        # ZipExtFile verifies the member's CRC-32 at end of stream.
        with archive.open(info) as source, open(destination, "wb") as target:
            shutil.copyfileobj(source, target, 1 << 20)
        mode = (info.external_attr >> 16) & 0o777
        if mode:
            os.chmod(destination, mode)

    for slice in SLICES:
        digest = sha256(os.path.join(staging, slice, "VLCKit.framework", "VLCKit"))
        if digest != BINARY_SHA256[slice]:
            sys.exit(f"VLCKit {slice} binary SHA-256 mismatch: {digest}")

    info_plist = plistlib.loads(archive.read(f"{PREFIX}Info.plist"))
    libraries = [library for library in info_plist["AvailableLibraries"] if library["LibraryIdentifier"] in SLICES]
    for library in libraries:
        library.pop("DebugSymbolsPath", None)
    info_plist["AvailableLibraries"] = libraries
    with open(os.path.join(staging, "Info.plist"), "wb") as file:
        plistlib.dump(info_plist, file)
    with open(os.path.join(staging, STAMP), "w") as file:
        file.write(VERSION + "\n")

    shutil.rmtree(output, ignore_errors=True)
    os.rename(staging, output)
    print(f"VLCKit {VERSION} → {output}")


if __name__ == "__main__":
    main()
