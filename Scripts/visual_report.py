#!/usr/bin/env python3
"""Build a zero-dependency HTML visual comparison report."""

from __future__ import annotations

import argparse
import hashlib
import html
import shutil
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
    names = sorted(set(baseline) | set(candidate))

    rows: list[str] = []
    changed: list[str] = []

    for name in names:
        before = baseline.get(name)
        after = candidate.get(name)
        state = "NEW" if before is None else "REMOVED" if after is None else "UNCHANGED" if digest(before) == digest(after) else "CHANGED"

        if state != "UNCHANGED":
            changed.append(f"{state}: {name}")

        before_rel = ""
        after_rel = ""
        if before:
            shutil.copy2(before, before_dir / name)
            before_rel = f"before/{html.escape(name)}"
        if after:
            shutil.copy2(after, after_dir / name)
            after_rel = f"after/{html.escape(name)}"

        visual = ""
        if before and after:
            visual = f'''<div class="compare">
  <img src="{before_rel}" alt="Before {html.escape(name)}">
  <img class="after" id="after-{html.escape(name)}" src="{after_rel}" alt="After {html.escape(name)}">
</div>
<input type="range" min="0" max="100" value="50" oninput="document.getElementById('after-{html.escape(name)}').style.opacity=this.value/100">'''
        elif after:
            visual = f'<img class="single" src="{after_rel}" alt="New {html.escape(name)}">'
        elif before:
            visual = f'<img class="single" src="{before_rel}" alt="Removed {html.escape(name)}">'

        rows.append(f'''<section>
<h2>{html.escape(name)} <span class="state {state.lower()}">{state}</span></h2>
{visual}
</section>''')

    report = f'''<!doctype html>
<meta charset="utf-8">
<title>SchneeBar Visual Report</title>
<style>
body {{ font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; background: #111; color: #eee; }}
section {{ margin: 0 0 48px; padding: 20px; border: 1px solid #333; border-radius: 16px; }}
.compare {{ position: relative; display: inline-block; max-width: 100%; background: #222; }}
.compare img, .single {{ display: block; max-width: 720px; width: 100%; height: auto; }}
.compare .after {{ position: absolute; inset: 0; opacity: .5; }}
input[type=range] {{ width: min(720px, 100%); margin-top: 12px; }}
.state {{ font-size: 11px; padding: 3px 7px; border-radius: 999px; background: #333; }}
.changed, .new, .removed {{ background: #6b3d00; }}
.unchanged {{ background: #164b2d; }}
</style>
<h1>SchneeBar Visual Regression Report</h1>
<p>Move the slider to overlay the PR render on top of the main-branch render.</p>
{''.join(rows) if rows else '<p>No snapshots were generated.</p>'}
'''
    (args.output / "index.html").write_text(report, encoding="utf-8")

    summary_lines = ["## Visual Regression", ""]
    if changed:
        summary_lines.append(f"Changed/new/removed scenarios: **{len(changed)}**")
        summary_lines.extend(f"- `{line}`" for line in changed)
    else:
        summary_lines.append("No rendered image changes detected.")
    summary_lines.extend(["", "Download the `visual-regression-report` artifact to open the Before / After / Overlay HTML report."])
    (args.output / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

    print("\n".join(summary_lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
