"""Check the actual PE icon payload against every resolution in the chosen ICO."""
import argparse
import struct
from pathlib import Path


def word(data, offset):
    return struct.unpack_from('<H', data, offset)[0]


def integer(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def icons_from_pe(data):
    pe = integer(data, 0x3C)
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('Expected a PE executable.')
    optional = pe + 24
    directory = optional + (112 if word(data, optional) == 0x20B else 96)
    resource_rva = integer(data, directory + 16)
    sections = optional + word(data, pe + 20)

    def file_offset(rva):
        for index in range(word(data, pe + 6)):
            section = sections + 40 * index
            start = integer(data, section + 12)
            size = max(integer(data, section + 8), integer(data, section + 16))
            if start <= rva < start + size:
                return integer(data, section + 20) + rva - start
        raise ValueError('Resource RVA outside sections.')

    base = file_offset(resource_rva)
    resources = {}

    def visit(offset, path):
        header = base + offset
        count = word(data, header + 12) + word(data, header + 14)
        for index in range(count):
            entry = header + 16 + 8 * index
            name, target = struct.unpack_from('<II', data, entry)
            if name & 0x80000000:
                text_offset = base + (name & 0x7FFFFFFF)
                length = word(data, text_offset)
                name = data[text_offset + 2:text_offset + 2 + 2 * length].decode('utf-16-le')
            route = path + (name,)
            if target & 0x80000000:
                visit(target & 0x7FFFFFFF, route)
            else:
                rva, size = struct.unpack_from('<II', data, base + target)
                start = file_offset(rva)
                resources[route] = data[start:start + size]

    visit(0, ())
    return resources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('ico', type=Path)
    args = parser.parse_args()
    ico = args.ico.read_bytes()
    if ico[:4] != b'\0\0\1\0':
        raise ValueError('Expected ICO file.')
    frames = []
    sizes = []
    for index in range(word(ico, 4)):
        entry = 6 + 16 * index
        size, offset = struct.unpack_from('<II', ico, entry + 8)
        frames.append(ico[offset:offset + size])
        sizes.append((ico[entry] or 256, ico[entry + 1] or 256))
    resources = icons_from_pe(args.executable.read_bytes())
    images = [blob for path, blob in resources.items() if path[0] == 3]
    groups = [(path, blob) for path, blob in resources.items() if path[0] == 14]
    if not all(frame in images for frame in frames):
        raise ValueError('Executable is missing one or more selected icon frames.')
    # Check that one named or numbered group references all chosen frames,
    # rather than
    # requiring it to have exactly the source ICO's entry count.
    complete_group = False
    for route, group in groups:
        identifiers = [word(group, 6 + 14 * i + 12)
                       for i in range(word(group, 4))]
        referenced = [resources.get((3, identifier, route[-1]))
                      for identifier in identifiers]
        if all(frame in referenced for frame in frames):
            complete_group = True
            break
    if not complete_group:
        raise ValueError('No full multi-resolution icon group found.')
    print(f'PASS: {args.executable.name} embeds selected ICO frames {sizes}')


if __name__ == '__main__':
    main()
