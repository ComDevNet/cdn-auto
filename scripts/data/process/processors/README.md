# Processors

Python scripts that parse logs and build summary.csv.

- [log.py](./log.py) — Apache (Server v4) access logs
- [logv2.py](./logv2.py) — OC4D (Server v5) logs
- [castle.py](./castle.py) — Cape Coast Castle variant of v5 logs

Implementation notes

- Ensure required Python packages in [requirements.txt](../../../requirements.txt) are installed
- Regexes in the processors must match the actual log format; prefer named groups to avoid index drift
- Inputs: v4 expects Apache combined lines; v5 expects JSON lines with a message
- Outputs: per-file CSVs and a run-level summary.csv (headers vary per processor; see parent README)
- Error handling: castle.py writes JSON/regex/timestamp issues to error_log.txt; logv2.py prints skipped lines
- Performance: processors stream line-by-line; summary.csv is combined from per-file CSVs to keep memory steady
