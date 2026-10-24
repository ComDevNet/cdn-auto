#!/usr/bin/env python3
"""Parse `aws s3 ls --recursive` listing files into per-day coverage.

IMPORTANT: never pipe `aws s3 ls` into this script's stdin while also feeding a
heredoc — the heredoc steals stdin and you get 0 objects. Pass a listing file:

  aws s3 ls "$PREFIX" --recursive > /tmp/s3_ls.txt
  python3 s3_day_coverage.py /tmp/s3_ls.txt [--sane-bytes N] [--local-days d1,d2]
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict


DAILY_RE = re.compile(r"_(\d{2})_(\d{2})_(\d{4})_(?:access_logs|modulegaze_logs)\.csv$", re.I)
NR_RE = re.compile(r"_nr_(\d{8})_", re.I)


def parse_day_from_basename(bn: str) -> tuple[str | None, str]:
    m = DAILY_RE.search(bn)
    if m:
        return f"{m.group(3)}-{m.group(2)}-{m.group(1)}", "daily"
    m2 = NR_RE.search(bn)
    if m2:
        d = m2.group(1)
        return f"{d[:4]}-{d[4:6]}-{d[6:8]}", "nr"
    return None, "other"


def load_listing(
    path: str, device: str = ""
) -> dict[str, list[tuple[str, int, str]]]:
    by: dict[str, list[tuple[str, int, str]]] = defaultdict(list)
    device = (device or "").strip()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            try:
                size = int(parts[2])
            except ValueError:
                continue
            key = parts[3]
            bn = key.rsplit("/", 1)[-1]
            if device and not bn.startswith(f"{device}_"):
                continue
            day, kind = parse_day_from_basename(bn)
            if day:
                by[day].append((kind, size, bn))
    return by


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("listing_file", help="Path to aws s3 ls --recursive output")
    ap.add_argument("--sane-bytes", type=int, default=50 * 1024 * 1024)
    ap.add_argument(
        "--device",
        default="",
        help="Only count objects whose basename starts with this DEVICE_LOCATION",
    )
    ap.add_argument(
        "--local-days",
        default="",
        help="Comma-separated YYYY-MM-DD days present in local source logs",
    )
    ap.add_argument(
        "--report-gaps",
        action="store_true",
        help="Print only local days missing a sane S3 object (one per line)",
    )
    ap.add_argument(
        "--summary",
        action="store_true",
        help="Print human-readable coverage summary to stderr; gaps to stdout if --report-gaps",
    )
    args = ap.parse_args()

    by = load_listing(args.listing_file, device=args.device)
    local_days = [d.strip() for d in args.local_days.split(",") if d.strip()]

    if args.summary or not args.report_gaps:
        total_objs = sum(len(v) for v in by.values())
        sys.stderr.write(f"S3 listing: {total_objs} dated object(s) across {len(by)} day(s)\n")
        if local_days:
            sys.stderr.write(f"Local source days: {len(local_days)}\n")
            for day in sorted(local_days):
                items = by.get(day, [])
                sane = [x for x in items if x[1] <= args.sane_bytes]
                huge = [x for x in items if x[1] > args.sane_bytes]
                if not items:
                    flag = "MISSING"
                elif not sane and huge:
                    flag = "CORRUPT-ONLY"
                elif huge:
                    flag = "OK+HUGE"
                else:
                    flag = "OK"
                maxsz = max((x[1] for x in items), default=0)
                sys.stderr.write(
                    f"  {day}: n={len(items)} sane={len(sane)} huge={len(huge)} "
                    f"max={maxsz} {flag}\n"
                )

    gaps: list[str] = []
    for day in sorted(local_days):
        items = by.get(day, [])
        sane = [x for x in items if x[1] <= args.sane_bytes]
        if not sane:
            gaps.append(day)

    if args.report_gaps:
        for day in gaps:
            print(day)
    elif not args.summary:
        # Default: dump covered days with at least one sane object
        for day in sorted(by):
            if any(sz <= args.sane_bytes for _, sz, _ in by[day]):
                print(day)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
