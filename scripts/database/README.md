# Database (OC4D PostgreSQL)

Backup and restore for the local Docker Postgres used by `oc4d-server` on the Pi.

Menu: main → **6. Database** → `scripts/database/main.sh`

## Defaults

| Setting | Value |
|---------|--------|
| Container | `oc4d_db` (`OC4D_DB_CONTAINER`) |
| Database | `oc4d` (`OC4D_DB_NAME`) |
| User | `postgres` (`OC4D_DB_USER`) |
| Backup directory | `/var/backups/oc4d/database` |
| Filename | `oc4d-backup-YYYY-MM-DD_HH-MM-SS.sql.gz` |
| Retention | last **10** files (`OC4D_DB_BACKUP_MAX`) |
| Timer | `oc4d-db-backup.timer` — every **6 hours**, `OnBootSec=15min` |
| Log | `/var/log/oc4d-db-backup/backup.log` |
| Web service (may stop on restore) | `oc4d.service` (`OC4D_WEB_SERVICE`) |

## Commands

```bash
sudo ./scripts/database/install.sh    # install / enable timer
sudo ./scripts/database/backup.sh     # backup now
sudo ./scripts/database/restore.sh    # interactive restore
sudo ./scripts/database/restore.sh --list
sudo ./scripts/database/restore.sh --file /var/backups/oc4d/database/oc4d-backup-….sql.gz
./scripts/database/status.sh          # timer + backup list
```

## Behavior notes

- Backups use `pg_dump` inside the Docker container, gzipped on the host.
- Restore creates a `pre-restore-*.sql.gz` snapshot first, then applies `--clean` dump content.
- Restore may stop `OC4D_WEB_SERVICE` while applying; confirm before running on a live site.
- Directory permissions are set via `scripts/lib/permissions.sh` (`ensure_oc4d_backup_dirs`).

See also: [docs/DEVELOPER-WIKI.md](../../docs/DEVELOPER-WIKI.md) §8.
