#!/usr/bin/env python3
"""Self-check for rolling near-realtime + legacy windows. Run from this dir or via validate_near_realtime.sh"""

from datetime import datetime

from time_window import compute_window


def main() -> None:
    now = datetime(2026, 9, 14, 14, 22, 30)

    daily = compute_window("daily", now=now)
    assert daily.file_stamp == "13_09_2026", daily.file_stamp
    assert daily.end.day == 13

    hourly = compute_window("hourly", now=now)
    assert hourly.start.hour == 13 and hourly.end.hour == 13

    weekly = compute_window("weekly", now=now)
    assert weekly.end.day == 13

    monthly = compute_window("monthly", now=now)
    assert monthly.file_stamp == "08_2026", monthly.file_stamp

    nr = compute_window("near_realtime", now=now, run_interval_seconds=900)
    assert nr.start == datetime(2026, 9, 14, 0, 0, 0), nr.start
    assert nr.end == datetime(2026, 9, 14, 14, 22, 30), nr.end
    assert nr.file_stamp == "nr_20260914_1415_900s", nr.file_stamp

    later = compute_window(
        "near_realtime", now=datetime(2026, 9, 14, 14, 28, 0), run_interval_seconds=900
    )
    assert later.file_stamp == nr.file_stamp
    assert later.start == nr.start

    nxt = compute_window(
        "near_realtime", now=datetime(2026, 9, 14, 14, 30, 0), run_interval_seconds=900
    )
    assert nxt.file_stamp != nr.file_stamp
    assert nxt.start == datetime(2026, 9, 14, 0, 0, 0)
    assert nxt.end == datetime(2026, 9, 14, 14, 30, 0)

    print("PASS: near_realtime + legacy schedule windows")


if __name__ == "__main__":
    main()
