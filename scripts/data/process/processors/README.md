# Processors

Python scripts that parse logs and build summary.csv.

- [log.py](./log.py) — Apache (Server v4) access logs
- [logv2.py](./logv2.py) — OC4D (Server v5) logs
- [castle.py](./castle.py) — Cape Coast Castle variant of v5 logs
- [dhub.py](./dhub.py) — D-Hub (Server v3) UUID-based module logs
- [log-v6.py](./log-v6.py) — Server v6 (OC4D with module paths) logs

Implementation notes

- Ensure required Python packages in [requirements.txt](../../../requirements.txt) are installed
- Regexes in the processors must match the actual log format; prefer named groups to avoid index drift
- Inputs: v4 expects Apache combined lines; v5 expects JSON lines with a message; v3 expects JSON with extended D-Hub module paths; v6 expects JSON with module paths similar to v3 but stored in /var/log/oc4d
- Outputs: per-file CSVs and a run-level summary.csv (headers vary per processor; see parent README)
- Error handling: castle.py writes JSON/regex/timestamp issues to error_log.txt; logv2.py, dhub.py, and log-v6.py print skipped lines
- Module extraction: dhub.py and log-v6.py handle `/uploads/modules/[id]/[module-name]`, `/modules/[id]/[module-name]`, and `/uploads/other-modules/[module-name]` path formats
- Performance: processors stream line-by-line; summary.csv is combined from per-file CSVs to keep memory steady
