# Kolibri Summary Automation Report

Date: 2026-04-06
Target device: `pi@192.168.8.171`
Repo: `/home/pi/cdn-auto`

## What changed

- Kolibri summary exports now use the same schedule window as the main automation flow.
- Daily runs export only the previous day.
- Weekly runs export only the previous full week.
- Monthly runs export only the previous month.
- Yearly runs export only the previous full calendar year.
- Hourly runs export only the previous completed hour.
- Custom-interval automation runs export the last completed configured interval length.
- Kolibri filenames are now deterministic per period, so rerunning the same period overwrites the same S3 object instead of creating duplicates with new timestamps.

## Why this was changed

The earlier Kolibri implementation exported a growing all-time summary snapshot every run. Over time that would keep increasing file size and could also cause downstream processing to ingest the same day more than once if multiple snapshots for the same period were uploaded.

The updated flow keeps Kolibri aligned with the normal `RACHEL/` schedule boundaries and avoids duplicate-period objects.

## Current behavior

### Automation

When the automation schedule is set to:

- `daily`: Kolibri exports yesterday only
- `weekly`: Kolibri exports the previous full Monday-to-Sunday week
- `monthly`: Kolibri exports the previous full month
- `yearly`: Kolibri exports the previous full calendar year
- `hourly`: Kolibri exports the previous completed hour
- `custom`: Kolibri exports the last fully completed `RUN_INTERVAL` window

The output is uploaded to:

- `S3_BUCKET/S3_SUBFOLDER/Kolibri/<period-based-filename>.csv`

### Manual process

The manual Kolibri upload flow now prompts the user to choose one of these options:

- use the configured automation schedule
- export the last completed hourly, daily, weekly, monthly, or yearly period
- enter an exact start date and end date manually

Manual custom date-range exports also use deterministic filenames based on the chosen start and end dates so rerunning the same manual range replaces the same S3 object path. If the manually entered dates exactly match a standard day, week, month, or year window, the export reuses that standard period filename instead of creating a second object key for the same slice.

## Important implementation note

The Pi is running Kolibri `0.19.2`, whose `exportlogs` command crashes unless explicit `--start_date` and `--end_date` values are supplied. The new implementation always passes the exact schedule window dates to avoid that bug.
