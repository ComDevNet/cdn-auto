# Processing

Turn collected logs into CSV summaries.

Processors

- v1/v4 → scripts/data/process/processors/log.py
- v2/v5 (oc4d) → scripts/data/process/processors/logv2.py
- v2/v5 (cape_coast_d) → scripts/data/process/processors/castle.py

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

- Menu: ./scripts/data/process/main.sh
- Direct: ./scripts/data/process/logs.sh
