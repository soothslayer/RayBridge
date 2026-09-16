#!/usr/bin/env python3
"""Check the archived bundle for the four App Store validation failures seen in build 1."""
import plistlib
import struct
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def png_size(path):
    data = path.read_bytes()
    require(data[:8] == b'\x89PNG\r\n\x1a\n', f'{path.name} is not a PNG')
    offset = 8
    # Xcode may put a CgBI chunk before IHDR when optimizing PNGs.
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        if data[offset + 4:offset + 8] == b'IHDR':
            return struct.unpack('>II', data[offset + 8:offset + 16])
        offset += 12 + length
    raise ValueError(f'{path.name} has no PNG header')


def verify(archive):
    apps = list((archive / 'Products' / 'Applications').glob('*.app'))
    require(len(apps) == 1, 'Expected exactly one app in the archive')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require((app / 'Assets.car').is_file(), 'Compiled asset catalog is missing')
    for key, pixels in [('CFBundleIcons', 120), ('CFBundleIcons~ipad', 152)]:
        icon = info.get(key, {}).get('CFBundlePrimaryIcon', {})
        require(icon.get('CFBundleIconName') == 'AppIcon', f'{key}: CFBundleIconName is missing or incorrect')
        names = icon.get('CFBundleIconFiles', [])
        files = [p for p in app.glob('*.png') if any(p.name.startswith(name) for name in names)]
        require(any(png_size(p) == (pixels, pixels) for p in files),
                f'{key}: no referenced {pixels}x{pixels} PNG in bundle')
    orientations = set(info.get('UISupportedInterfaceOrientations~ipad',
                                info.get('UISupportedInterfaceOrientations', [])))
    require(orientations == {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                             'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'},
            'iPad must declare all four orientations for multitasking')
    print(f"Archive checks passed: build {info['CFBundleVersion']}, AppIcon metadata, 120/152px icons, and iPad orientations.")


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2, 'Usage: verify-ios-archive.py PATH.xcarchive')
        verify(Path(sys.argv[1]))
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        sys.exit(f'Archive validation failed: {error}')
