"""Convert the selected PNG into Windows icon sizes without altering its design.

Run from app/: python tool/create_icon.py ../doc/design/icon_options/c_sticker.png
Requires Pillow. The selected source PNG is retained verbatim for provenance.
"""
import argparse
import shutil
from pathlib import Path

from PIL import Image

APP = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    branding = APP / 'assets' / 'branding'
    branding.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, branding / 'app_icon_source.png')
    with Image.open(source) as image:
        if image.width != image.height:
            raise ValueError('The selected icon must be square.')
        image = image.convert('RGBA')
        # Keep the chosen background verbatim, including opaque white artwork.
        image.resize((256, 256), Image.Resampling.LANCZOS).save(
            branding / 'app_icon_256.png'
        )
        icon_path = APP / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
        image.save(icon_path, format='ICO', sizes=[
            (size, size) for size in (16, 24, 32, 48, 64, 128, 256)
        ])
    with Image.open(icon_path) as icon:
        sizes = icon.ico.sizes()
        if sizes != {(size, size) for size in (16, 24, 32, 48, 64, 128, 256)}:
            raise ValueError(f'Unexpected ICO sizes: {sizes}')
    print(f'Created {icon_path} with {len(sizes)} sizes; original background preserved.')


if __name__ == '__main__':
    main()
