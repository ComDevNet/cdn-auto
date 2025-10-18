# Processing

Turn collected logs into CSV summaries.

Processors

- v1/v4 → [processors/log.py](./processors/log.py)
- v2/v5 (oc4d) → [processors/logv2.py](./processors/logv2.py)
- v2/v5 (cape_coast_d) → [processors/castle.py](./processors/castle.py)

Outputs

- summary.csv written to 00_DATA/00_PROCESSED/RUN_FOLDER/
- Individual per-file CSVs are also generated alongside summary.csv

CSV schemas

- v4/log.py: columns = [IP Address, Access Date, Module Viewed, Status Code, Data Saved (GB), Device Used, Browser Used]
- v5/logv2.py: columns = [IP Address, Access Date, Module Viewed, Status Code, Data Saved (GB), Device Used, Browser Used]
- v5/castle.py: columns = [IP Address, Access Date, Access Time, Module Viewed, Location Viewed, Status Code, Data Saved (GB), Device Used, Browser Used]

Notes & edge cases

- logv2.py expects each line to be JSON with a message field containing a combined-log-like string
- castle.py parses a more structured message; it logs regex and timestamp errors into error_log.txt in the processed folder and normalizes IPv6 ::ffff: prefix
- All processors normalize sizes to gigabytes and parse user agents to OS family and browser family

Usage

- Menu: [main.sh](./main.sh)
- Direct: [logs.sh](./logs.sh)
