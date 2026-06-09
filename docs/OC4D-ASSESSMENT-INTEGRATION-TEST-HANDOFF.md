# OC4D Assessment Pull Integration — Implementation & Test Handoff

This document records **everything implemented** across three repos so another agent (or human) can run verification without re-reading the full conversation or plan file.

**Plan reference (do not edit):** `oc4d-assessment-pull_ef12ff58.plan.md`  
**Spec notes:** `C:\Users\llewe\Documents\01-NOTES\CDN-Notes\📓 Notes\📑 Quick Notes\cdn-auto assessment pulling.md`

---

## 1. High-level outcome

The system should:

1. Pull assessment results from the **local Pi OC4D server API** (`oc4d-server`): `GET /api/assessment-results?scope=all`
2. Resolve cloud `studentId` and `assessmentId` via CSV mapping files (hard-fail if unmapped)
3. Build validated CSV artifacts (header + ≥1 data row)
4. Upload to S3 at strict keys:

   `{parentOrg}/Assessments/{studentId}/{assessmentId}/{base}__{isoTs}.csv`

5. Queue failed/offline uploads in `00_DATA/00_UPLOAD_QUEUE/OC4DAssessments/` with `.oc4dkey` sidecars
6. Keep existing **RACHEL / Kolibri / ModuleGaze** pipelines unchanged

Supporting identity work was also done in `oc4d-server` (username + login) and `oc4d` (student email/username in admin UI).

---

## 2. Repos involved

| Repo | Path | Role |
|------|------|------|
| **cdn-auto** | `C:\Users\llewe\Documents\00-CODES\cdn-auto` | Main automation: API pull → CSV → S3 upload/queue |
| **oc4d-server** | `C:\Users\llewe\Documents\00-CODES\oc4d-server` | Pi-hosted OC4D app; Postgres `AssessmentResult`; source API |
| **oc4d** | `C:\Users\llewe\Documents\00-CODES\oc4d` | Cloud OC4D; student admin UI + DynamoDB students lambda |

**Live Pi (from recon):** `192.168.1.189` — has `oc4d-server`, `/var/log/oc4d`. At time of implementation, `AssessmentResult` had **0 rows** (E2E blocked until seeded).

---

## 3. cdn-auto — files created

| File | Purpose |
|------|---------|
| `scripts/data/lib/oc4d_assessment_helpers.sh` | Bash helpers: S3 key builder, key validation, OC4D bucket region detect, direct S3 upload, queue with `.oc4dkey` sidecar, queue flush, API fetch via curl |
| `scripts/data/process/processors/assessment.py` | Python processor: API pull + optional source-dir CSV ingest, ID mapping, CSV validation, staging artifacts, `manifest.json`, upload state tracking |
| `scripts/data/upload/oc4d_assessments.sh` | Manual menu entry: run processor + upload/queue |
| `config/oc4d/student-map.csv` | Starter student mapping file (comment examples only) |
| `config/oc4d/assessment-map.csv` | Starter assessment mapping file (comment examples only) |
| `docs/OC4D-ASSESSMENT-INTEGRATION-TEST-HANDOFF.md` | This document |

---

## 4. cdn-auto — files modified

| File | What changed |
|------|--------------|
| `scripts/data/automation/configure.sh` | Added OC4D config prompts (v2/v6 only), defaults, summary display, persistence to `config/automation.conf` |
| `scripts/data/automation/runner.sh` | Loads OC4D vars; sources `oc4d_assessment_helpers.sh`; adds isolated `process_oc4d_assessments()` stage after ModuleGaze |
| `scripts/data/lib/s3_helpers.sh` | `prepare_queue_dirs` creates `OC4DAssessments/`; `flush_all_queues` calls `flush_oc4d_queue` |
| `scripts/data/automation/flush_queue.sh` | Detects queued files in `OC4DAssessments/` |
| `scripts/data/automation/status.sh` | Shows OC4D config + `OC4DAssessments` queue count |
| `scripts/data/upload/main.sh` | New menu option **4. Upload OC4D Assessments** (renumbered 5–8) |
| `scripts/data/README.md` | Documents OC4D stage, mapping files, S3 key contract |
| `scripts/data/automation/README.md` | Full OC4D config keys, data flow step 4, troubleshooting |
| `scripts/data/process/processors/README.md` | Lists `assessment.py` |
| `config/README.md` | Documents OC4D config keys + mapping file paths |

---

## 5. cdn-auto — configuration contract

Written by `configure.sh` into `config/automation.conf`:

| Key | Default | Description |
|-----|---------|-------------|
| `OC4D_ASSESSMENTS_ENABLED` | `0` | `1` to enable assessment pull stage |
| `OC4D_API_BASE_URL` | `http://127.0.0.1:3000` | Base URL for local `oc4d-server` |
| `OC4D_API_TOKEN` | `""` | Bearer token for super-admin `scope=all` API access |
| `OC4D_BUCKET` | `oc4d-raw-reports` | Destination bucket (name or `s3://...`) |
| `OC4D_PARENT_ORG` | `Home-Schooling` | S3 key prefix / parent org |
| `OC4D_UPLOAD_MODE` | `direct_s3` | Only `direct_s3` implemented; `presigned_api` reserved |
| `OC4D_SOURCE_DIR` | `""` | Optional folder of pre-exported CSV files |
| `OC4D_STUDENT_MAP_FILE` | `config/oc4d/student-map.csv` | Student identity → cloud `studentId` |
| `OC4D_ASSESSMENT_MAP_FILE` | `config/oc4d/assessment-map.csv` | Assessment identity → cloud `assessmentId` |
| `OC4D_STATE_FILE` | `00_DATA/00_OC4D_ASSESSMENTS/uploaded-state.json` | Tracks uploaded result IDs (idempotency) |

OC4D prompts only appear when `SERVER_VERSION` is **v2** or **v6** during configure.

---

## 6. Mapping files (required for successful uploads)

### `config/oc4d/student-map.csv`

```csv
source_student_name,studentId,parentOrg
```

Lookup keys (case-insensitive) tried in order:

- `user.email`
- `user.username`
- `user.name`
- `result.userId` (UUID)

**Hard-fail** if no row matches.

### `config/oc4d/assessment-map.csv`

```csv
source_assessment_name,assessmentId,parentOrg
```

Lookup keys tried:

- Local `assessmentId` (UUID)
- `assessment.title`

**Hard-fail** if no row matches.

Rows starting with `#` in the first column are skipped. Empty mapping files cause all results to fail validation.

---

## 7. S3 upload contract

**Bucket:** `OC4D_BUCKET` (separate from main `S3_BUCKET` used by RACHEL/Kolibri/ModuleGaze)

**Key pattern (strict):**

```
{parentOrg}/Assessments/{studentId}/{assessmentId}/{base}__{isoTs}.csv
```

**Examples:**

```
Home-Schooling/Assessments/student-uuid/assess-uuid/module-1-quiz__2026-06-09T15-30-00Z.csv
```

**Rules:**

- `{base}` = sanitized lowercase assessment title (non-alphanumeric → `-`)
- `{isoTs}` = result `createdAt` ISO string with `:` replaced by `-`
- CSV must have header row + ≥1 non-empty data row
- No duplicate header names after trim+lower normalize
- First column should be `Timestamp`; remaining columns are question prompts

---

## 8. Data flow (runtime)

```
oc4d-server GET /api/assessment-results?scope=all&take=2000
        ↓
assessment.py (fetch, map IDs, build CSV per result)
        ↓
00_DATA/00_OC4D_ASSESSMENTS/staging_YYYYMMDD_HHMMSS/
  ├── {key-basename}.csv
  └── manifest.json
        ↓
runner.sh / oc4d_assessments.sh
        ↓
  [online]  upload_oc4d_one → s3://OC4D_BUCKET/{full-key}
  [offline] queue_oc4d_one → 00_UPLOAD_QUEUE/OC4DAssessments/{file}.csv
                              + {file}.csv.oc4dkey (contains full S3 key)
        ↓
Next online run: flush_all_queues → flush_oc4d_queue
```

**Idempotency:** Successfully uploaded API `result.id` values are appended to `OC4D_STATE_FILE` (`{"uploadedIds": [...]}`). Already-uploaded IDs are skipped.

**Optional source-dir mode:** If `OC4D_SOURCE_DIR` is set, `*.csv` files there are also processed. Filename convention: `{assessmentName}__{studentName}.csv` (both segments used as mapping lookup keys).

---

## 9. API details (oc4d-server)

**Endpoint:** `GET {OC4D_API_BASE_URL}/api/assessment-results?scope=all&take={take}`

**Auth:** `Authorization: Bearer {OC4D_API_TOKEN}` if token set

**Requirements:**

- Caller must be **super admin** for `scope=all` (returns 403 otherwise)
- Response shape:

```json
{
  "data": [ /* AssessmentResult rows with optional user + assessment */ ],
  "questionsByAssessmentId": { "assessment-uuid": [ /* questions */ ] },
  "total": 0,
  "scope": "all"
}
```

**Each result used for CSV generation needs:**

- `id`, `assessmentId`, `userId`, `answers`, `createdAt`
- Attached `user` with `email`, `username`, `name` (when `scope=all`)
- Attached `assessment.title`
- Questions in `questionsByAssessmentId[assessmentId]`

**Submit endpoint (for seeding test data):** `POST /api/assessment-results` with `{ assessmentId, answers, score?, passed? }`

---

## 10. Queue mechanism (OC4D-specific)

Unlike RACHEL/Kolibri/ModuleGaze (folder + basename), OC4D uses **full prebuilt S3 keys**.

| Queue path | Contents |
|------------|----------|
| `00_DATA/00_UPLOAD_QUEUE/OC4DAssessments/foo.csv` | CSV payload |
| `00_DATA/00_UPLOAD_QUEUE/OC4DAssessments/foo.csv.oc4dkey` | Single line: full S3 key (no bucket prefix) |

`flush_oc4d_queue` uploads `s3://{OC4D_BUCKET}/{key-from-sidecar}` and deletes both files on success.

---

## 11. Commands for testing

### Configure (on Pi)

```bash
cd /path/to/cdn-auto
sudo ./scripts/data/automation/configure.sh
# Enable OC4D assessments when prompted (Server v5/v6)
```

### Fill mapping files

```bash
# Edit with real cloud IDs
nano config/oc4d/student-map.csv
nano config/oc4d/assessment-map.csv
```

### Manual assessment pull + upload

```bash
./scripts/data/upload/oc4d_assessments.sh
```

### Full automation run

```bash
sudo /usr/local/bin/run_v5_log_processor.sh
# or
sudo ./scripts/data/automation/runner.sh
```

### Flush queue only

```bash
./scripts/data/automation/flush_queue.sh
```

### Status dashboard

```bash
./scripts/data/automation/status.sh
```

### Local smoke tests (no Pi required)

**Bash key builder:**

```bash
cd cdn-auto
source scripts/data/lib/oc4d_assessment_helpers.sh
build_oc4d_assessment_key "Home-Schooling" "stu" "asm" "quiz" "2026-06-09T15:30:00Z"
# Expected: Home-Schooling/Assessments/stu/asm/quiz__2026-06-09T15-30-00Z.csv
```

**Python key builder:**

```bash
py -3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('a','scripts/data/process/processors/assessment.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.build_object_key('Home-Schooling','student-uuid','assess-uuid','Module 1 Quiz','2026-06-09T15:30:00Z'))
"
# Expected: Home-Schooling/Assessments/student-uuid/assess-uuid/module-1-quiz__2026-06-09T15-30-00Z.csv
```

---

## 12. Suggested test plan for another AI

### A. Unit / smoke (local, no network)

- [ ] Bash `build_oc4d_assessment_key` returns exact contract path
- [ ] Python `build_object_key` matches bash output for same inputs
- [ ] `validate_oc4d_assessment_key` rejects malformed keys (missing `Assessments` segment, wrong suffix)
- [ ] `validate_csv_file` rejects: empty file, header-only, duplicate headers
- [ ] Mapping loader skips `#` comment rows
- [ ] `resolve_student_mapping` hard-fails with explicit reason when unmapped
- [ ] `resolve_assessment_mapping` hard-fails when unmapped

### B. Processor (mock API or fixture JSON)

Create a fixture JSON matching API response with 1 result, 2 questions, mapped student/assessment:

- [ ] `assessment.py` writes staging CSV with `Timestamp` + question prompt columns
- [ ] `manifest.json` has `ready` entry with correct `s3_key` and `csv` path
- [ ] Re-running with same `result.id` in state file → entry in `skipped`
- [ ] Unmapped student → `failed` with `missing studentId mapping` reason
- [ ] Unmapped assessment → `failed` with `missing assessmentId mapping` reason

### C. Integration on Pi (`192.168.1.189`)

**Prerequisites:**

1. `oc4d-server` running and reachable at configured `OC4D_API_BASE_URL`
2. Migration applied: `20260609154500_add_user_username`
3. Super-admin API token configured in `OC4D_API_TOKEN`
4. Mapping files populated with real cloud IDs
5. At least one `AssessmentResult` row in Postgres (submit via UI or API)

**Tests:**

- [ ] `curl -H "Authorization: Bearer $TOKEN" "$API/api/assessment-results?scope=all"` returns data
- [ ] `./scripts/data/upload/oc4d_assessments.sh` produces staging dir + manifest
- [ ] S3 object appears at `{parentOrg}/Assessments/{studentId}/{assessmentId}/...csv`
- [ ] `uploaded-state.json` contains result ID after successful upload
- [ ] Simulate offline (block S3 or disconnect network): file queued with `.oc4dkey` sidecar
- [ ] Restore network + `flush_queue.sh`: queued file uploaded and removed from queue
- [ ] Full `runner.sh` run: RACHEL/Kolibri/ModuleGaze still work; assessment stage logs `[oc4d][report] uploaded=...`

### D. S3 acceptance (cloud OC4D ingestion)

After upload, verify downstream (if access available):

- [ ] Object key matches strict pattern
- [ ] CSV parses (header first row, ≥1 data row)
- [ ] OC4D ingest writes `raw-assessment` rows with `assessmentId` populated
- [ ] Student dashboard shows graded result

### E. Identity workstream (oc4d-server)

- [ ] `username` column exists and is unique (migration applied)
- [ ] Existing users backfilled (email local-part; collisions get `_2`, `_3`, etc.)
- [ ] Login with **email** works: `POST /api/authentication` `{ "identifier": "user@example.com", "password": "..." }`
- [ ] Login with **username** works: `{ "identifier": "username", "password": "..." }`
- [ ] Backward compat: `{ "email": "user@example.com", "password": "..." }` still works
- [ ] Sign-in UI label reads "Username or Email"
- [ ] Assessment submit resolves canonical user UUID (not raw email in `userId`)

### F. Identity workstream (oc4d cloud)

- [ ] Student create/edit modal has `studentEmail` and `studentUsername` fields
- [ ] Values persist via `students.ts` lambda
- [ ] Bulk CSV matching tries email/username/studentId before name/fuzzy match

---

## 13. oc4d-server — files changed (identity + assessment API)

| File | Change |
|------|--------|
| `libs/prisma/schema.prisma` | Added `username String @unique` on `User` |
| `libs/prisma/migrations/20260609154500_add_user_username/migration.sql` | Add column, backfill from email local-part, collision suffix, NOT NULL + unique index |
| `app/api/authentication/route.ts` | Accepts `identifier` (or legacy `email`); resolves user by email OR username |
| `app/authentication/sign-in/page.tsx` | Form field `identifier`, label "Username or Email" |
| `contexts/AuthContext.tsx` | Posts `identifier` to auth API |
| `app/api/users/route.ts` | Username validation on create |
| `app/api/users/[id]/route.ts` | Username validation on update |
| `app/api/signup/route.ts` | Username on signup |
| `app/admin/technical/manage-users/page.tsx` | Username column/field in admin UI |
| `libs/auth/accessControl.ts` | Username-derived keys in access/result resolution |
| `app/api/assessment-results/route.ts` | `attachUsers` resolves by id/email/username; canonical UUID on submit |
| `libs/prisma/seed.ts` | Username in seed data |
| `scripts/rbac-db-setup.mjs` | Username in RBAC setup |

**Pi migration command (typical):**

```bash
cd /home/pi/oc4d-server/workspaces/website
npm run db:migrate   # or project-specific migrate command
npm run db:generate
```

---

## 14. oc4d — files changed (student admin)

| File | Change |
|------|--------|
| `workspaces/website/app/admin/students/page.tsx` | `studentEmail` / `studentUsername` in create, edit, detail modals; payload + metadata persistence |
| `workspaces/infra/lib/lambda/students.ts` | `studentEmail`, `studentUsername` on create/patch; bulk CSV matching prefers email/username/studentId |

---

## 15. Validation rules enforced (hard-fail)

| Rule | Where enforced |
|------|----------------|
| Not `.csv` | source-dir mode only |
| Missing `studentId` mapping | `assessment.py` |
| Missing `assessmentId` mapping | `assessment.py` |
| Empty header row | `assessment.py` `validate_csv_file` |
| Zero data rows | `assessment.py` |
| Duplicate header names (trim+lower) | `assessment.py` |
| Key missing required segments | `assessment.py` + `validate_oc4d_assessment_key` in bash |
| No questions for assessment | `assessment.py` |

Failures are recorded in `manifest.json` under `failed` with `reason` text. The runner logs `[oc4d][report] uploaded=... skipped=... failed=...` and does **not** fail the overall RACHEL/Kolibri run.

---

## 16. Directory layout after a run

```
cdn-auto/
├── config/
│   ├── automation.conf          # includes OC4D_* keys when configured
│   └── oc4d/
│       ├── student-map.csv
│       └── assessment-map.csv
└── 00_DATA/
    ├── 00_OC4D_ASSESSMENTS/
    │   ├── staging_YYYYMMDD_HHMMSS/
    │   │   ├── manifest.json
    │   │   └── *.csv
    │   └── uploaded-state.json
    └── 00_UPLOAD_QUEUE/
        └── OC4DAssessments/
            ├── *.csv
            └── *.csv.oc4dkey
```

---

## 17. Known gaps / not implemented

| Item | Status |
|------|--------|
| `OC4D_UPLOAD_MODE=presigned_api` | Reserved; runner warns and uses `direct_s3` |
| **oc4d cloud** sign-in (`oc4d` repo Cognito flow) updated to `identifier` | **Not done** — only `oc4d-server` offline auth updated |
| Cross-repo identity sync (oc4d ↔ oc4d-server) | Manual via mapping CSVs; no live API sync |
| Pi E2E with real assessment data | Blocked until `AssessmentResult` rows exist + mappings filled |
| Preflight mapping API (`GET /students/{parentOrg}/assessment-ingest-mapping`) | Not implemented (was optional in spec notes) |

---

## 18. Troubleshooting quick reference

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `[oc4d] Disabled in config` | `OC4D_ASSESSMENTS_ENABLED=0` | Re-run `configure.sh`, enable assessments |
| API 403 on `scope=all` | Token not super-admin | Use super-admin account token |
| API 401 | Missing/invalid token | Set `OC4D_API_TOKEN` |
| All results `failed` / missing mapping | Empty or wrong mapping CSVs | Fill `config/oc4d/*.csv` |
| Queue not flushing | Missing `.oc4dkey` sidecar | Ensure pair exists; re-queue via manual script |
| Upload to wrong bucket | `OC4D_BUCKET` vs `S3_BUCKET` confusion | OC4D uses `OC4D_BUCKET` only |
| Duplicate uploads | State file not updating | Check `OC4D_STATE_FILE` writable; verify `result_id` in manifest |

---

## 19. Acceptance criteria (definition of done)

From the plan + spec notes:

- [ ] `cdn-auto` uploads to `{parentOrg}/Assessments/{studentId}/{assessmentId}/...csv` in `oc4d-raw-reports` (or configured bucket)
- [ ] Trigger/ingest writes `raw-assessment` rows with `assessmentId` populated
- [ ] `fetchAssessments` + `fetchStudentFiles(raw-assessment)` load successfully
- [ ] `findAssessmentForResult` matches by `assessmentId` (not fuzzy fallback)
- [ ] `gradeAssessmentAnswers` renders percentages/trends per student consistently
- [ ] Offline queue flush works on next online run
- [ ] RACHEL/Kolibri/ModuleGaze behavior unchanged

---

## 20. Todo checklist (all marked complete in implementation session)

| ID | Description | Repo |
|----|-------------|------|
| add-oc4d-config-vars | OC4D config keys + configure.sh | cdn-auto |
| build-assessment-helpers | `oc4d_assessment_helpers.sh` | cdn-auto |
| create-assessment-processor | `assessment.py` | cdn-auto |
| wire-runner-stage | `process_oc4d_assessments()` in runner | cdn-auto |
| extend-s3-queue-routing | `OC4DAssessments` queue + contract-key upload | cdn-auto |
| docs-and-manual-entrypoints | READMEs + `oc4d_assessments.sh` + upload menu | cdn-auto |
| oc4d-add-username-field | Unique `username` + migration/backfill | oc4d-server |
| oc4d-login-username-or-email | `identifier` login API + UI | oc4d-server |
| oc4d-result-identity-resolution | Canonical UUID on assessment submit/fetch | oc4d-server |
| oc4d-student-email-entry-screen | Student email/username in admin UI | oc4d |

---

*Generated for test handoff. Update this file if implementation changes.*
