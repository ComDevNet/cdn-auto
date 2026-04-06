#!/usr/bin/env python3

import shlex
import sys
from dataclasses import dataclass
from datetime import datetime, time, timedelta


@dataclass
class Window:
    start: datetime
    end: datetime
    file_stamp: str
    label: str


def compute_window(
    schedule_type: str,
    now: datetime | None = None,
    run_interval_seconds: int | None = None,
) -> Window:
    now = now or datetime.now()

    if schedule_type == "hourly":
        target_hour = now - timedelta(hours=1)
        start = target_hour.replace(minute=0, second=0, microsecond=0)
        end = target_hour.replace(minute=59, second=59, microsecond=0)
        return Window(
            start=start,
            end=end,
            file_stamp=target_hour.strftime("%H_%d_%m_%Y"),
            label=f"{start.strftime('%Y-%m-%d %H:00')} to {end.strftime('%H:%M:%S')}",
        )

    if schedule_type == "daily":
        target_day = now - timedelta(days=1)
        start = datetime.combine(target_day.date(), time.min).replace(microsecond=0)
        end = datetime.combine(target_day.date(), time(23, 59, 59))
        return Window(
            start=start,
            end=end,
            file_stamp=target_day.strftime("%d_%m_%Y"),
            label=f"{start.strftime('%Y-%m-%d')} (entire day)",
        )

    if schedule_type == "weekly":
        today = now.date()
        start_of_this_week = today - timedelta(days=today.weekday())
        start_of_last_week = start_of_this_week - timedelta(weeks=1)
        end_of_last_week = start_of_last_week + timedelta(days=6)
        start = datetime.combine(start_of_last_week, time.min).replace(microsecond=0)
        end = datetime.combine(end_of_last_week, time(23, 59, 59))
        return Window(
            start=start,
            end=end,
            file_stamp=start_of_last_week.strftime("%W_%m_%Y"),
            label=(
                f"Week {start_of_last_week.strftime('%W')} "
                f"({start.strftime('%Y-%m-%d')} to {end_of_last_week.strftime('%Y-%m-%d')})"
            ),
        )

    if schedule_type == "monthly":
        first_day_this_month = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        end_of_last_month = first_day_this_month - timedelta(seconds=1)
        start_of_last_month = end_of_last_month.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return Window(
            start=start_of_last_month,
            end=end_of_last_month,
            file_stamp=end_of_last_month.strftime("%m_%Y"),
            label=end_of_last_month.strftime("%B %Y"),
        )

    if schedule_type == "yearly":
        target_year = now.year - 1
        start = datetime(target_year, 1, 1, 0, 0, 0)
        end = datetime(target_year, 12, 31, 23, 59, 59)
        return Window(
            start=start,
            end=end,
            file_stamp=str(target_year),
            label=str(target_year),
        )

    if schedule_type == "custom":
        if run_interval_seconds is None or run_interval_seconds < 1:
            raise ValueError("Custom schedule type requires a positive RUN_INTERVAL in seconds.")

        epoch = datetime(1970, 1, 1)
        now_seconds = int((now - epoch).total_seconds())
        completed_boundary = (now_seconds // run_interval_seconds) * run_interval_seconds
        end = epoch + timedelta(seconds=completed_boundary - 1)
        start = end - timedelta(seconds=run_interval_seconds - 1)
        return Window(
            start=start,
            end=end,
            file_stamp=f"custom_{start.strftime('%Y%m%d_%H%M%S')}_{run_interval_seconds}s",
            label=(
                f"Last completed {run_interval_seconds}s interval "
                f"({start.strftime('%Y-%m-%d %H:%M:%S')} to {end.strftime('%Y-%m-%d %H:%M:%S')})"
            ),
        )

    raise ValueError(f"Unsupported schedule type: {schedule_type}")


def build_filename(
    location: str,
    schedule_type: str,
    suffix: str,
    now: datetime | None = None,
    window: Window | None = None,
    run_interval_seconds: int | None = None,
) -> str:
    window = window or compute_window(schedule_type, now=now, run_interval_seconds=run_interval_seconds)
    return f"{location}_{window.file_stamp}_{suffix}.csv"


def emit_shell(schedule_type: str, location: str, suffix: str, run_interval_seconds: int | None = None) -> None:
    window = compute_window(schedule_type, run_interval_seconds=run_interval_seconds)
    values = {
        "WINDOW_START_DATE": window.start.strftime("%Y-%m-%dT%H:%M:%S"),
        "WINDOW_END_DATE": window.end.strftime("%Y-%m-%dT%H:%M:%S"),
        "WINDOW_LABEL": window.label,
        "WINDOW_FILENAME": build_filename(
            location,
            schedule_type,
            suffix,
            window=window,
            run_interval_seconds=run_interval_seconds,
        ),
        "WINDOW_FILE_STAMP": window.file_stamp,
        "WINDOW_SCHEDULE_TYPE": schedule_type,
    }

    if run_interval_seconds is not None:
        values["WINDOW_RUN_INTERVAL_SECONDS"] = str(run_interval_seconds)

    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.stderr.write("Usage: python time_window.py <schedule_type> <location> <suffix> [run_interval_seconds]\n")
        sys.exit(1)

    try:
        run_interval_seconds = int(sys.argv[4]) if len(sys.argv) == 5 and sys.argv[4] else None
        emit_shell(sys.argv[1], sys.argv[2], sys.argv[3], run_interval_seconds=run_interval_seconds)
    except ValueError as exc:
        sys.stderr.write(f"{exc}\n")
        sys.exit(1)
