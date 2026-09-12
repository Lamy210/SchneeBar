#!/usr/bin/env python3
"""Build a zero-dependency HTML visual comparison report."""

from __future__ import annotations

import argparse
import hashlib
import html
import shutil
import sys
from collections import Counter
from pathlib import Path


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    before_dir = args.output / "before"
    after_dir = args.output / "after"
    before_dir.mkdir(exist_ok=True)
    after_dir.mkdir(exist_ok=True)

    baseline = {p.name: p for p in args.baseline.glob("*.png")}
    candidate = {p.name: p for p in args.candidate.glob("*.png")}

    if not candidate:
        print("Visual regression failed: candidate renderer produced no PNG snapshots.", file=sys.stderr)
        return 2

    names = sorted(set(baseline) | set(candidate))

    rows: list[str] = []
    changed: list[str] = []
    states: Counter[str] = Counter()

    for index, name in enumerate(names):
        before = baseline.get(name)
        after = candidate.get(name)
        state = (
            "NEW"
            if before is None
            else "REMOVED"
            if after is None
            else "UNCHANGED"
            if digest(before) == digest(after)
            else "CHANGED"
        )
        states[state] += 1

        if state != "UNCHANGED":
            changed.append(f"{state}: {name}")

        before_rel = ""
        after_rel = ""
        escaped_name = html.escape(name)

        if before:
            shutil.copy2(before, before_dir / name)
            before_rel = f"before/{escaped_name}"
        if after:
            shutil.copy2(after, after_dir / name)
            after_rel = f"after/{escaped_name}"

        side_by_side = ""
        overlay = ""

        if before and after:
            side_by_side = f'''<div class="pair">
  <figure><figcaption>Before · PR base</figcaption><img src="{before_rel}" alt="Before {escaped_name}"></figure>
  <figure><figcaption>After · PR candidate</figcaption><img src="{after_rel}" alt="After {escaped_name}"></figure>
</div>'''
            overlay_id = f"overlay-after-{index}"
            overlay = f'''<details>
<summary>Overlay comparison</summary>
<div class="compare">
  <img src="{before_rel}" alt="Before overlay {escaped_name}">
  <img class="after" id="{overlay_id}" src="{after_rel}" alt="After overlay {escaped_name}">
</div>
<label>Candidate opacity <input type="range" min="0" max="100" value="50" oninput="document.getElementById('{overlay_id}').style.opacity=this.value/100"></label>
</details>'''
        elif after:
            side_by_side = f'<figure class="single"><figcaption>New snapshot</figcaption><img src="{after_rel}" alt="New {escaped_name}"></figure>'
        elif before:
            side_by_side = f'<figure class="single"><figcaption>Removed snapshot</figcaption><img src="{before_rel}" alt="Removed {escaped_name}"></figure>'

        rows.append(
            f'''<section>
<h2>{escaped_name} <span class="state {state.lower()}">{state}</span></h2>
{side_by_side}
{overlay}
</section>'''
        )

    report = f'''<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SchneeBar Visual Report</title>
<style>
:root {{ color-scheme: dark; }}
body {{ font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; background: #111; color: #eee; }}
header {{ margin-bottom: 28px; }}
section {{ margin: 0 0 48px; padding: 20px; border: 1px solid #333; border-radius: 16px; background: #171717; }}
.pair {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }}
figure {{ margin: 0; min-width: 0; }}
figcaption {{ margin-bottom: 8px; color: #bbb; font-weight: 600; }}
.pair img, .single img, .compare img {{ display: block; max-width: 720px; width: 100%; height: auto; border-radius: 10px; }}
.compare {{ position: relative; display: inline-block; width: min(720px, 100%); margin-top: 12px; background: #222; border-radius: 10px; overflow: hidden; }}
.compare .after {{ position: absolute; inset: 0; opacity: .5; }}
details {{ margin-top: 16px; }}
details summary {{ cursor: pointer; font-weight: 600; }}
label {{ display: block; margin-top: 8px; color: #bbb; }}
input[type=range] {{ display: block; width: min(720px, 100%); margin-top: 8px; }}
.state {{ font-size: 11px; padding: 3px 7px; border-radius: 999px; background: #333; }}
.changed, .new, .removed {{ background: #6b3d00; }}
.unchanged {{ background: #164b2d; }}
.summary {{ display: flex; gap: 12px; flex-wrap: wrap; color: #bbb; }}
@media (max-width: 900px) {{ .pair {{ grid-template-columns: 1fr; }} body {{ margin: 16px; }} }}
</style>
<header>
<h1>SchneeBar Visual Regression Report</h1>
<p>Side-by-side images are the primary review surface. Expand Overlay comparison for pixel-aligned inspection.</p>
<div class="summary">
<span>Changed: {states['CHANGED']}</span>
<span>New: {states['NEW']}</span>
<span>Removed: {states['REMOVED']}</span>
<span>Unchanged: {states['UNCHANGED']}</span>
</div>
</header>
{''.join(rows)}
'''
    (args.output / "index.html").write_text(report, encoding="utf-8")

    summary_lines = ["## Visual Regression", ""]
    summary_lines.append(
        " · ".join(
            [
                f"Changed **{states['CHANGED']}**",
                f"New **{states['NEW']}**",
                f"Removed **{states['REMOVED']}**",
                f"Unchanged **{states['UNCHANGED']}**",
            ]
        )
    )
    if changed:
        summary_lines.extend(["", "Review these scenarios:"])
        summary_lines.extend(f"- `{line}`" for line in changed)
    else:
        summary_lines.extend(["", "No rendered image changes detected."])
    summary_lines.extend(
        [
            "",
            "Download the `visual-regression-report` artifact to open the side-by-side / overlay HTML report.",
        ]
    )
    (args.output / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

    print("\n".join(summary_lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
