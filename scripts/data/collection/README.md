# Collection

Collect server logs from:

- v4 (Apache) at /var/log/apache2 (access.log*)
- v5 (OC4D) at /var/log/oc4d (oc4d-*.log, capecoastcastle-*.log, *.gz; excludes *exceptions*)
- v3 (D-Hub) at /var/log/dhub (*.log)
- v6 (Server v6) at /var/log/oc4d (v6-*.log; excludes *exceptions*)
- ModuleGaze at /var/log/modulegaze (active session log and daily session .log.zip archives)

Outputs

- Creates a run folder in 00_DATA named LOCATION_logs_YYYY_MM_DD, or LOCATION_modulegaze_logs_YYYY_MM_DD for ModuleGaze
- Copies relevant files there
- Decompresses any .gz files in-place for the existing server log processors
- Skips exception logs (e.g., oc4d-exceptions-*.log) to avoid noise

Usage

- Run the menu: [scripts/data/collection/main.sh](../../data/collection/main.sh)
- To collect directly: [scripts/data/collection/all.sh](../../data/collection/all.sh)

Inner workings

- The script prompts for server type and device location (used in the folder name)
- v4 copies files matching access.log* from /var/log/apache2
- v5 copies oc4d logs, Cape Coast Castle logs, and any *.gz files
- v3 copies *.log files from /var/log/dhub
- v6 copies v6-*.log files from /var/log/oc4d
- ModuleGaze copies only modulegaze-sessions.log and modulegaze-sessions-*.log.zip from /var/log/modulegaze
- The resulting folder is moved into 00_DATA for the processing stage
