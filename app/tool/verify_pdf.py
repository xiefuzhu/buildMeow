"""Raster-check the PDF mosaic fixture using independent PDF tooling.

Run with a Python runtime containing pdfplumber, pypdf and Pillow, with
pdftoppm on PATH: python tool/verify_pdf.py build/qa/pdf_after_mapItem.pdf
"""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

import pdfplumber
from PIL import Image
from pypdf import PdfReader


def verify(path):
    path = Path(path)
    manifest = json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
    prefix = path.with_suffix('')
    subprocess.run(['pdftoppm', '-r', '144', '-png', str(path), str(prefix)], check=True)
    reader = PdfReader(path)
    text = '\n'.join(p.extract_text() for p in reader.pages)
    compact = re.sub(r'\s+', '', text)
    for material in manifest['materials']:
        assert material in compact, f'Material omitted: {material}'
    images = {int(p.stem.rsplit('-', 1)[1]): p for p in path.parent.glob(prefix.name + '-*.png')}
    checked = []
    with pdfplumber.open(path) as pdf:
        for index, page in enumerate(pdf.pages):
            for char in page.chars:
                assert -0.1 <= char['top'] <= char['bottom'] <= page.height + 0.1, 'Text leaves page'
            rects = [r for r in page.rects if r['fill'] and 0.01 < r['height'] < 6 and r['width'] >= r['height']]
            heights = collections.Counter(round(r['height'], 3) for r in rects)
            if not heights or heights.most_common(1)[0][1] < 128:
                continue  # Legend continuation and global materials pages.
            cell_height = heights.most_common(1)[0][0]
            rects = [r for r in rects if abs(r['height'] - cell_height) < 0.002]
            bounds = (min(r['x0'] for r in rects), min(r['top'] for r in rects),
                      max(r['x1'] for r in rects), max(r['bottom'] for r in rects))
            page_text = re.sub(r'\s+', '', reader.pages[index].extract_text())
            tile = re.search(r'第(\d+)张.*第(\d+)行第(\d+)列', page_text)
            x0, y0, columns, rows = (0, 0, manifest['width'], manifest['height'])
            if tile:
                x0, y0 = (int(tile.group(3)) - 1) * 128, (int(tile.group(2)) - 1) * 128
                columns = rows = 128
                assert sum(line['stroke'] for line in page.lines) >= 18, 'Chunk lines missing'
            assert abs((bounds[2] - bounds[0]) / columns - (bounds[3] - bounds[1]) / rows) < 0.002, 'Aspect ratio distorted'
            for char in page.chars:
                overlaps = char['x0'] < bounds[2] and char['x1'] > bounds[0] and char['top'] < bounds[3] and char['bottom'] > bounds[1]
                assert not overlaps, 'Text overlaps the diagram'
            image = Image.open(images[index + 1]).convert('RGB')
            scale_x, scale_y = image.width / page.width, image.height / page.height
            for sample in manifest['samples']:
                if not (x0 <= sample['x'] < x0 + columns and y0 <= sample['y'] < y0 + rows):
                    continue
                x = bounds[0] + (sample['x'] - x0 + 0.5) * (bounds[2] - bounds[0]) / columns
                y = bounds[1] + (sample['y'] - y0 + 0.5) * (bounds[3] - bounds[1]) / rows
                actual = image.getpixel((int(x * scale_x), int(y * scale_y)))
                assert max(abs(a - b) for a, b in zip(actual, sample['rgb'])) <= 3, f'Page {index + 1}: {actual} != {sample["rgb"]}'
            checked.append(index + 1)
    assert len(checked) == 3, f'Expected overview and two tiles, found {checked}'
    result = {'passed': True, 'pages': len(reader.pages), 'diagramPages': checked,
              'checks': ['pixel colors and orientation', 'chunk strokes', 'aspect ratio', 'text bounds', 'no overlaps', 'complete materials']}
    path.with_name(path.stem + '_report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    verify(sys.argv[1])
