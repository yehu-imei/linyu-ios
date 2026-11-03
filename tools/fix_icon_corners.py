"""Remove only the border-connected dark corners of the original app icon.

Never redraw or resample the foreground. Fail if the mask leaves the corner
triangles, and retain a byte-for-byte backup before replacing the asset.
"""
import argparse
from collections import deque
from pathlib import Path
import shutil

from PIL import Image


def repair(source: Path, backup: Path) -> None:
    original = Image.open(source).convert("RGB")
    width, height = original.size
    assert (width, height) == (1024, 1024)
    background = original.getpixel((width // 2, 0))
    assert min(background) >= 250
    pending = deque([(0, 0), (width - 1, 0), (0, height - 1),
                     (width - 1, height - 1)])
    checked = set()
    mask = set()
    while pending:
        x, y = pending.popleft()
        if not (0 <= x < width and 0 <= y < height) or (x, y) in checked:
            continue
        checked.add((x, y))
        if min(original.getpixel((x, y))) >= 251:
            continue
        # Exterior corners end before 220 px; fail instead of touching artwork.
        assert min(x, width - 1 - x) + min(y, height - 1 - y) < 220
        mask.add((x, y))
        pending.extend(((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)))
    assert 40000 < len(mask) < 60000, "Unexpected source icon; inspect manually"
    output = original.copy()
    for point in mask:
        output.putpixel(point, background)
    assert not backup.exists(), "Do not overwrite an existing original backup"
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, backup)
    output.save(source, format="PNG")
    saved = Image.open(source)
    assert saved.mode == "RGB" and saved.size == original.size
    changed = {(i % width, i // width) for i, (before, after) in
               enumerate(zip(original.getdata(), saved.getdata())) if before != after}
    assert changed == mask, "Pixels outside corner mask changed"
    print(f"Changed {len(changed)} corner pixels; all other pixels identical.")
    print(f"Original backup: {backup}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("backup", type=Path)
    args = parser.parse_args()
    repair(args.source, args.backup)
