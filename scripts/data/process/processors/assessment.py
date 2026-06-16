#!/usr/bin/env python3
"""
Fetch OC4D assessment results (API and/or source CSV folder), resolve cloud IDs via
mapping files, validate CSV shape, and emit upload-ready artifacts plus manifest.json.
"""

from __future__ import annotations

import csv
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_KEY_PATTERN = re.compile(
    r"^[^/]+/Assessments/[^/]+/[^/]+/[^/]+__[^/]+\.csv$"
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_ts_for_key(value: str | None) -> str:
    raw = (value or utc_now_iso()).strip()
    return raw.replace(":", "-")


def safe_base_name(value: str, fallback: str = "assessment-result") -> str:
    cleaned = re.sub(r"[^a-z0-9._-]+", "-", value.strip().lower())
    cleaned = cleaned.strip("-")
    return cleaned or fallback


def normalize_key_segment(value: str) -> str:
    return value.strip().strip("/")


def build_object_key(
    parent_org: str,
    student_id: str,
    assessment_id: str,
    base: str,
    iso_ts: str,
) -> str:
    parent_org = normalize_key_segment(parent_org)
    student_id = normalize_key_segment(student_id)
    assessment_id = normalize_key_segment(assessment_id)
    base = safe_base_name(base)
    iso_ts = iso_ts_for_key(iso_ts)
    if not all([parent_org, student_id, assessment_id, base, iso_ts]):
        raise ValueError("missing required key segments")
    key = f"{parent_org}/Assessments/{student_id}/{assessment_id}/{base}__{iso_ts}.csv"
    if not REQUIRED_KEY_PATTERN.match(key):
        raise ValueError(f"invalid object key: {key}")
    return key


def load_mapping_file(
    path: Path,
    required_columns: tuple[str, ...],
    *,
    missing_ok: bool = False,
) -> list[dict[str, str]]:
    if not path.exists():
        if missing_ok:
            return []
        raise FileNotFoundError(f"mapping file not found: {path}")

    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"mapping file has no header: {path}")
        missing = [col for col in required_columns if col not in reader.fieldnames]
        if missing:
            raise ValueError(f"mapping file {path} missing columns: {', '.join(missing)}")
        for row in reader:
            source = (row.get(required_columns[0]) or "").strip()
            if not source or source.startswith("#"):
                continue
            normalized = {col: (row.get(col) or "").strip() for col in required_columns}
            if not all(normalized.values()):
                continue
            rows.append(normalized)
    return rows


def index_mapping(rows: list[dict[str, str]], source_key: str) -> dict[str, dict[str, str]]:
    indexed: dict[str, dict[str, str]] = {}
    for row in rows:
        key = row[source_key].strip().lower()
        indexed[key] = row
    return indexed


def warn(message: str) -> None:
    print(json.dumps({"warn": message}), file=sys.stderr)


def normalize_identity(value: Any) -> str:
    return str(value or "").strip().lower()


def username_from_email(value: Any) -> str:
    email = normalize_identity(value)
    if "@" not in email:
        return ""
    return email.split("@", 1)[0].strip()


def student_id_slug(value: Any) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    return safe_base_name(raw)


def bool_from_env(value: str, default: bool = False) -> bool:
    raw = value.strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "y", "on"}


def mapping_rows_for_cloud_student(student: dict[str, Any], default_parent_org: str) -> list[dict[str, str]]:
    metadata = student.get("metadata")
    if isinstance(metadata, str):
        try:
            metadata = json.loads(metadata)
        except json.JSONDecodeError:
            metadata = {}
    if not isinstance(metadata, dict):
        metadata = {}

    student_id = str(student.get("studentId") or student.get("id") or "").strip()
    if not student_id:
        return []
    if bool(student.get("archived")):
        return []

    parent_org = str(student.get("parentOrg") or default_parent_org).strip() or default_parent_org
    display_name = str(student.get("displayName") or student.get("name") or "").strip()
    email = str(
        student.get("studentEmail")
        or student.get("email")
        or metadata.get("studentEmail")
        or metadata.get("email")
        or ""
    ).strip()
    username = str(
        student.get("studentUsername")
        or student.get("username")
        or metadata.get("studentUsername")
        or metadata.get("username")
        or ""
    ).strip()

    keys = [
        student_id,
        display_name,
        email,
        username,
        username_from_email(email),
        student_id_slug(display_name),
        student_id_slug(email),
        student_id_slug(username),
        student_id_slug(username_from_email(email)),
    ]

    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for key in keys:
        normalized = normalize_identity(key)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        rows.append(
            {
                "source_student_name": normalized,
                "studentId": student_id,
                "parentOrg": parent_org,
            }
        )
    return rows


def students_from_payload(payload: Any, default_parent_org: str) -> list[dict[str, str]]:
    if isinstance(payload, dict):
        raw_students = (
            payload.get("students")
            or payload.get("data")
            or payload.get("items")
            or payload.get("results")
            or []
        )
    elif isinstance(payload, list):
        raw_students = payload
    else:
        raw_students = []

    rows: list[dict[str, str]] = []
    if not isinstance(raw_students, list):
        return rows
    for student in raw_students:
        if isinstance(student, dict):
            rows.extend(mapping_rows_for_cloud_student(student, default_parent_org))
    return rows


def read_json_or_csv_mapping(raw: str, default_parent_org: str) -> list[dict[str, str]]:
    text = raw.strip()
    if not text:
        return []
    if text[0] in "[{":
        return students_from_payload(json.loads(text), default_parent_org)

    rows: list[dict[str, str]] = []
    reader = csv.DictReader(text.splitlines())
    for row in reader:
        if not row:
            continue
        if {"source_student_name", "studentId", "parentOrg"}.issubset(row.keys()):
            source = (row.get("source_student_name") or "").strip()
            if source:
                rows.append(
                    {
                        "source_student_name": source,
                        "studentId": (row.get("studentId") or "").strip(),
                        "parentOrg": (row.get("parentOrg") or default_parent_org).strip(),
                    }
                )
        else:
            rows.extend(mapping_rows_for_cloud_student(row, default_parent_org))
    return [row for row in rows if all(row.values())]


def fetch_url_text(url: str, token: str = "") -> str:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8")


def cloud_students_url(base_url: str, parent_org: str) -> str:
    base = base_url.rstrip("/")
    encoded_parent = urllib.parse.quote(parent_org, safe="")
    return f"{base}/students/{encoded_parent}"


def aws_region_args() -> list[str]:
    region = (
        os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
        or os.environ.get("OC4D_AWS_REGION")
        or ""
    ).strip()
    return ["--region", region] if region else []


def fetch_s3_text(s3_uri: str) -> str:
    cmd = ["aws", *aws_region_args(), "s3", "cp", s3_uri, "-"]
    result = subprocess.run(cmd, check=False, text=True, capture_output=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "aws s3 cp failed")
    return result.stdout


def parse_s3_bucket_uri(value: str) -> tuple[str, str]:
    raw = value.strip()
    if raw.startswith("s3://"):
        raw = raw[5:]
    raw = raw.strip("/")
    if not raw:
        return "", ""
    bucket, _, prefix = raw.partition("/")
    return bucket, prefix.strip("/")


def list_s3_common_prefixes(bucket_uri: str, prefix: str) -> list[str]:
    bucket, bucket_prefix = parse_s3_bucket_uri(bucket_uri)
    if not bucket:
        return []
    full_prefix = "/".join(part.strip("/") for part in (bucket_prefix, prefix) if part.strip("/"))
    if full_prefix and not full_prefix.endswith("/"):
        full_prefix += "/"

    prefixes: list[str] = []
    token = ""
    while True:
        cmd = [
            "aws",
            *aws_region_args(),
            "s3api",
            "list-objects-v2",
            "--bucket",
            bucket,
            "--prefix",
            full_prefix,
            "--delimiter",
            "/",
            "--output",
            "json",
        ]
        if token:
            cmd.extend(["--continuation-token", token])
        result = subprocess.run(cmd, check=False, text=True, capture_output=True, timeout=30)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "aws s3api list failed")
        payload = json.loads(result.stdout or "{}")
        for item in payload.get("CommonPrefixes") or []:
            item_prefix = str(item.get("Prefix") or "")
            student_id = item_prefix[len(full_prefix) :].strip("/").split("/", 1)[0].strip()
            if student_id:
                prefixes.append(student_id)
        if not payload.get("IsTruncated"):
            break
        token = str(payload.get("NextContinuationToken") or "")
        if not token:
            break
    return prefixes


def load_cloud_student_rows(default_parent_org: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []

    local_file = os.environ.get("OC4D_CLOUD_STUDENT_MAP_FILE", "").strip()
    if local_file:
        try:
            rows.extend(read_json_or_csv_mapping(Path(local_file).read_text(encoding="utf-8"), default_parent_org))
        except Exception as exc:
            warn(f"cloud student map file failed: {exc}")

    s3_uri = os.environ.get("OC4D_CLOUD_STUDENT_MAP_S3_URI", "").strip()
    if s3_uri:
        try:
            rows.extend(read_json_or_csv_mapping(fetch_s3_text(s3_uri), default_parent_org))
        except Exception as exc:
            warn(f"cloud student map S3 fetch failed: {exc}")

    exact_url = os.environ.get("OC4D_CLOUD_STUDENT_MAP_URL", "").strip()
    api_base = os.environ.get("OC4D_CLOUD_STUDENTS_API_BASE_URL", "").strip()
    token = os.environ.get("OC4D_CLOUD_API_TOKEN", "").strip()
    urls = []
    if exact_url:
        urls.append(exact_url.replace("{parentOrg}", urllib.parse.quote(default_parent_org, safe="")))
    if api_base:
        urls.append(cloud_students_url(api_base, default_parent_org))

    for url in urls:
        try:
            rows.extend(read_json_or_csv_mapping(fetch_url_text(url, token), default_parent_org))
        except Exception as exc:
            warn(f"cloud student map URL fetch failed for {url}: {exc}")

    return rows


def load_cloud_student_prefix_ids(
    bucket_uri: str,
    parent_org: str,
    unassigned_student_id: str,
) -> dict[str, str]:
    if not bucket_uri or not bool_from_env(os.environ.get("OC4D_STUDENT_PREFIX_SYNC", "1"), True):
        return {}

    ids: set[str] = set()
    for folder in ("Assessments", "StudentReports", "RACHEL", "Kolibri"):
        try:
            ids.update(list_s3_common_prefixes(bucket_uri, f"{parent_org}/{folder}/"))
        except FileNotFoundError:
            warn("aws CLI not found; skipping S3 student prefix sync")
            return {}
        except Exception as exc:
            warn(f"S3 student prefix sync failed for {folder}: {exc}")

    ignored = {normalize_identity(unassigned_student_id), ""}
    return {
        normalize_identity(student_id): student_id
        for student_id in ids
        if normalize_identity(student_id) not in ignored
    }


def student_prefix_candidates(
    *,
    user_id: str = "",
    user_name: str = "",
    user_email: str = "",
    user_username: str = "",
) -> list[str]:
    raw_candidates = [
        user_username,
        username_from_email(user_email),
        user_email,
        user_name,
        user_id,
    ]
    candidates: list[str] = []
    seen: set[str] = set()
    for raw in raw_candidates:
        for candidate in (normalize_identity(raw), student_id_slug(raw)):
            if candidate and candidate not in seen:
                seen.add(candidate)
                candidates.append(candidate)
    return candidates


def resolve_student_mapping(
    student_index: dict[str, dict[str, str]],
    default_parent_org: str,
    *,
    user_id: str = "",
    user_name: str = "",
    user_email: str = "",
    user_username: str = "",
) -> tuple[str, str]:
    candidates = [
        user_email.strip().lower(),
        user_username.strip().lower(),
        user_name.strip().lower(),
        user_id.strip().lower(),
        user_id.strip(),
    ]
    for candidate in candidates:
        if candidate and candidate in student_index:
            row = student_index[candidate]
            parent_org = row.get("parentOrg") or default_parent_org
            return row["studentId"], parent_org
    raise KeyError(
        "missing studentId mapping for "
        f"userId={user_id!r} email={user_email!r} username={user_username!r} name={user_name!r}"
    )


def resolve_student_id(
    student_index: dict[str, dict[str, str]],
    default_parent_org: str,
    unassigned_student_id: str,
    cloud_student_ids: dict[str, str] | None = None,
    *,
    user_id: str = "",
    user_name: str = "",
    user_email: str = "",
    user_username: str = "",
) -> tuple[str, str, bool]:
    try:
        student_id, parent_org = resolve_student_mapping(
            student_index,
            default_parent_org,
            user_id=user_id,
            user_name=user_name,
            user_email=user_email,
            user_username=user_username,
        )
        return student_id, parent_org, False
    except KeyError:
        for candidate in student_prefix_candidates(
            user_id=user_id,
            user_name=user_name,
            user_email=user_email,
            user_username=user_username,
        ):
            matched_student_id = cloud_student_ids.get(candidate) if cloud_student_ids else ""
            if matched_student_id:
                return matched_student_id, default_parent_org, False
        return unassigned_student_id, default_parent_org, True


def resolve_assessment_mapping(
    assessment_index: dict[str, dict[str, str]],
    default_parent_org: str,
    *,
    assessment_id: str = "",
    assessment_title: str = "",
) -> tuple[str, str, bool]:
    candidates = [
        assessment_id.strip().lower(),
        assessment_id.strip(),
        assessment_title.strip().lower(),
        assessment_title.strip(),
    ]
    for candidate in candidates:
        if candidate and candidate in assessment_index:
            row = assessment_index[candidate]
            parent_org = row.get("parentOrg") or default_parent_org
            return row["assessmentId"], parent_org, False

    fallback = safe_base_name(assessment_id, "assessment")
    generated_id = safe_base_name(assessment_title, fallback)
    return generated_id, default_parent_org, True


def parse_created_at(value: Any) -> str:
    if value is None:
        return utc_now_iso()
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    text = str(value).strip()
    if not text:
        return utc_now_iso()
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return text


def answer_to_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value)
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def option_text_for_index(question: dict[str, Any], selected_index: int | None) -> str:
    options = question.get("options") or []
    if selected_index is None or not isinstance(options, list):
        return ""
    if selected_index < 0 or selected_index >= len(options):
        return ""
    return str(options[selected_index])


def selected_answer_for(answers: Any, question: dict[str, Any], question_index: int) -> str:
    selected_index: int | None = None
    raw_answer: Any = None
    if isinstance(answers, list):
        raw_answer = answers[question_index] if question_index < len(answers) else None
        selected_index = raw_answer if isinstance(raw_answer, int) else None
    elif isinstance(answers, dict):
        review = answers.get("review")
        if isinstance(review, list) and question_index < len(review):
            item = review[question_index]
            if isinstance(item, dict):
                raw = item.get("selectedIndex")
                selected_index = raw if isinstance(raw, int) else None
                raw_answer = (
                    item.get("selectedAnswer")
                    or item.get("answer")
                    or item.get("value")
                    or raw
                )
            else:
                raw_answer = item
        if selected_index is None:
            selections = answers.get("selections")
            if isinstance(selections, dict):
                raw = selections.get(question.get("id")) or selections.get(str(question_index))
                selected_index = raw if isinstance(raw, int) else None
                raw_answer = raw
            else:
                raw = answers.get(question.get("id")) or answers.get(str(question_index))
                selected_index = raw if isinstance(raw, int) else None
                raw_answer = raw

    option_text = option_text_for_index(question, selected_index)
    return option_text or answer_to_text(raw_answer)


def unique_headers(headers: list[str]) -> list[str]:
    seen: dict[str, int] = {}
    unique: list[str] = []
    for idx, header in enumerate(headers, start=1):
        base = header.strip() or f"Column {idx}"
        key = base.strip().lower()
        count = seen.get(key, 0) + 1
        seen[key] = count
        unique.append(base if count == 1 else f"{base} {count}")
    return unique


def fallback_answer_columns(answers: Any) -> tuple[list[str], list[str]]:
    if isinstance(answers, list):
        if not answers:
            return ["Raw Answers"], [""]
        return [f"Answer {idx + 1}" for idx in range(len(answers))], [
            answer_to_text(value) for value in answers
        ]

    if isinstance(answers, dict):
        review = answers.get("review")
        if isinstance(review, list) and review:
            values = []
            for item in review:
                if isinstance(item, dict):
                    values.append(
                        answer_to_text(
                            item.get("selectedAnswer")
                            or item.get("answer")
                            or item.get("value")
                            or item.get("selectedIndex")
                        )
                    )
                else:
                    values.append(answer_to_text(item))
            return [f"Answer {idx + 1}" for idx in range(len(values))], values

        selections = answers.get("selections")
        if isinstance(selections, dict) and selections:
            items = sorted(selections.items(), key=lambda item: str(item[0]))
            return [f"Answer {key}" for key, _ in items], [
                answer_to_text(value) for _, value in items
            ]

        if answers:
            return ["Raw Answers"], [answer_to_text(answers)]

    return ["Raw Answers"], [answer_to_text(answers)]


def validate_csv_file(path: Path) -> None:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError("empty header row") from exc
        if not header or not any(cell.strip() for cell in header):
            raise ValueError("empty header row")
        normalized = [cell.strip().lower() for cell in header]
        if len(normalized) != len(set(normalized)):
            raise ValueError("duplicate header names after trim/lower normalize")
        data_rows = [row for row in reader if any(cell.strip() for cell in row)]
        if not data_rows:
            raise ValueError("zero data rows")


def write_result_csv(
    path: Path,
    timestamp: str,
    questions: list[dict[str, Any]],
    answers: Any,
    source_identity: dict[str, str] | None = None,
) -> None:
    headers = ["Timestamp"]
    row = [timestamp]
    if source_identity:
        headers.extend(
            ["Source Email", "Source Username", "Source Name", "Source User Id"]
        )
        row.extend(
            [
                source_identity.get("email", ""),
                source_identity.get("username", ""),
                source_identity.get("name", ""),
                source_identity.get("user_id", ""),
            ]
        )

    if questions:
        answer_headers = [
            (q.get("prompt") or f"Question {idx + 1}").strip()
            for idx, q in enumerate(questions)
        ]
        answer_values = [
            selected_answer_for(answers, question, idx)
            for idx, question in enumerate(questions)
        ]
    else:
        answer_headers, answer_values = fallback_answer_columns(answers)

    headers.extend(answer_headers)
    row.extend(answer_values)
    headers = unique_headers(headers)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(headers)
        writer.writerow(row)
    validate_csv_file(path)


def load_state(path: Path) -> set[str]:
    if not path.exists():
        return set()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return set()
    uploaded = payload.get("uploadedIds") or []
    return {str(item) for item in uploaded}


def save_state(path: Path, uploaded_ids: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"uploadedIds": sorted(uploaded_ids)}
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def resolve_api_token(api_base: str, token: str) -> str:
    if token:
        return token

    identifier = os.environ.get("OC4D_API_IDENTIFIER", "admin@comdevnet.com").strip()
    password = os.environ.get("OC4D_API_PASSWORD", "CDN2025!").strip()
    creds_file = os.environ.get("OC4D_API_CREDENTIALS_FILE", "").strip()
    if creds_file and Path(creds_file).is_file():
        for line in Path(creds_file).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key == "OC4D_API_IDENTIFIER" and value:
                identifier = value
            elif key == "OC4D_API_PASSWORD" and value:
                password = value

    auth_url = f"{api_base.rstrip('/')}/api/authentication"
    payload = json.dumps({"identifier": identifier, "password": password}).encode("utf-8")
    request = urllib.request.Request(
        auth_url,
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Local OC4D API auth failed ({exc.code}): {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Local OC4D API auth failed: {exc}") from exc

    access_token = str(body.get("accessToken") or "").strip()
    if not access_token:
        raise RuntimeError("Local OC4D API auth did not return accessToken")
    return access_token


def fetch_api_payload(api_base: str, token: str, take: int) -> dict[str, Any]:
    api_base = api_base.rstrip("/")
    url = f"{api_base}/api/assessment-results?scope=all&take={take}"

    def fetch_with_access_token(access_token: str) -> str:
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {access_token}",
        }
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read().decode("utf-8")

    access_token = resolve_api_token(api_base, token)
    try:
        body = fetch_with_access_token(access_token)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if token and exc.code in (401, 403):
            try:
                body = fetch_with_access_token(resolve_api_token(api_base, ""))
            except urllib.error.HTTPError as retry_exc:
                retry_detail = retry_exc.read().decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"API fetch failed after token refresh ({retry_exc.code}): {retry_detail}"
                ) from retry_exc
            except urllib.error.URLError as retry_exc:
                raise RuntimeError(f"API fetch failed after token refresh: {retry_exc}") from retry_exc
        else:
            raise RuntimeError(f"API fetch failed ({exc.code}): {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"API fetch failed: {exc}") from exc
    payload = json.loads(body)
    if not isinstance(payload, dict):
        raise RuntimeError("API response must be a JSON object")
    return payload


def process_api_results(
    payload: dict[str, Any],
    *,
    student_index: dict[str, dict[str, str]],
    cloud_student_ids: dict[str, str],
    assessment_index: dict[str, dict[str, str]],
    default_parent_org: str,
    unassigned_student_id: str,
    staging_dir: Path,
    uploaded_ids: set[str],
) -> tuple[list[dict[str, Any]], set[str]]:
    results = payload.get("data") or []
    questions_by_assessment = payload.get("questionsByAssessmentId") or {}
    if not isinstance(results, list):
        raise ValueError("API payload field 'data' must be an array")

    manifest_entries: list[dict[str, Any]] = []
    counts = {"uploaded": 0, "unassigned": 0, "skipped": 0, "failed": 0}

    for result in results:
        if not isinstance(result, dict):
            counts["failed"] += 1
            manifest_entries.append(
                {"status": "failed", "reason": "result row is not an object", "result_id": ""}
            )
            continue

        result_id = str(result.get("id") or "").strip()
        if result_id and result_id in uploaded_ids:
            counts["skipped"] += 1
            manifest_entries.append(
                {"status": "skipped", "reason": "already uploaded", "result_id": result_id}
            )
            continue

        assessment = result.get("assessment") or {}
        user = result.get("user") or {}
        assessment_id_local = str(result.get("assessmentId") or assessment.get("id") or "").strip()
        assessment_title = str(assessment.get("title") or "").strip()
        user_id = str(result.get("userId") or user.get("id") or "").strip()
        user_name = str(user.get("name") or "").strip()
        user_email = str(user.get("email") or "").strip()
        user_username = str(user.get("username") or "").strip()
        created_at = parse_created_at(result.get("createdAt"))
        answers = result.get("answers")

        try:
            student_id, parent_org, is_unassigned = resolve_student_id(
                student_index,
                default_parent_org,
                unassigned_student_id,
                cloud_student_ids,
                user_id=user_id,
                user_name=user_name,
                user_email=user_email,
                user_username=user_username,
            )
            (
                cloud_assessment_id,
                assessment_parent,
                auto_assessment_mapping,
            ) = resolve_assessment_mapping(
                assessment_index,
                default_parent_org,
                assessment_id=assessment_id_local,
                assessment_title=assessment_title,
            )
            parent_org = assessment_parent or parent_org
            questions = questions_by_assessment.get(assessment_id_local) or []
            if not isinstance(questions, list):
                questions = []

            base = safe_base_name(assessment_title or cloud_assessment_id)
            s3_key = build_object_key(
                parent_org,
                student_id,
                cloud_assessment_id,
                base,
                created_at,
            )
            file_name = s3_key.split("/")[-1]
            csv_path = staging_dir / file_name
            source_identity = None
            if is_unassigned:
                source_identity = {
                    "email": user_email,
                    "username": user_username,
                    "name": user_name,
                    "user_id": user_id,
                }
            write_result_csv(
                csv_path,
                created_at,
                questions,
                answers,
                source_identity=source_identity,
            )

            manifest_entries.append(
                {
                    "status": "ready",
                    "result_id": result_id,
                    "csv": str(csv_path),
                    "s3_key": s3_key,
                    "unassigned": is_unassigned,
                    "auto_assessment_mapping": auto_assessment_mapping,
                    "question_count": len(questions),
                    "used_answer_fallback": len(questions) == 0,
                }
            )
            if is_unassigned:
                counts["unassigned"] += 1
            counts["uploaded"] += 1
        except (KeyError, ValueError) as exc:
            counts["failed"] += 1
            manifest_entries.append(
                {
                    "status": "failed",
                    "reason": str(exc),
                    "result_id": result_id,
                }
            )

    print(
        json.dumps(
            {
                "source": "api",
                "counts": counts,
                "entries": manifest_entries,
            }
        )
    )
    return manifest_entries, uploaded_ids


def normalize_source_csv(source_path: Path, dest_path: Path) -> None:
    raw = source_path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    text = raw.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    lines = [line for line in text.split("\n") if line.strip()]
    if not lines:
        raise ValueError(f"empty csv: {source_path}")
    while lines and lines[0].strip().startswith("#"):
        lines.pop(0)
    if not lines:
        raise ValueError(f"csv has no header row: {source_path}")
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    dest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    validate_csv_file(dest_path)


def process_source_dir(
    source_dir: Path,
    *,
    student_index: dict[str, dict[str, str]],
    assessment_index: dict[str, dict[str, str]],
    default_parent_org: str,
    staging_dir: Path,
) -> list[dict[str, Any]]:
    manifest_entries: list[dict[str, Any]] = []
    counts = {"uploaded": 0, "skipped": 0, "failed": 0}

    for source_csv in sorted(source_dir.glob("*.csv")):
        stem = source_csv.stem
        parts = stem.split("__")
        source_assessment = parts[0] if parts else stem
        source_student = parts[1] if len(parts) > 1 else stem
        try:
            student_id, parent_org = resolve_student_mapping(
                student_index,
                default_parent_org,
                user_id=source_student,
                user_name=source_student,
                user_email=source_student,
                user_username=source_student,
            )
            (
                cloud_assessment_id,
                assessment_parent,
                auto_assessment_mapping,
            ) = resolve_assessment_mapping(
                assessment_index,
                default_parent_org,
                assessment_id=source_assessment,
                assessment_title=source_assessment,
            )
            parent_org = assessment_parent or parent_org
            timestamp = utc_now_iso()
            base = safe_base_name(source_assessment)
            s3_key = build_object_key(
                parent_org,
                student_id,
                cloud_assessment_id,
                base,
                timestamp,
            )
            file_name = s3_key.split("/")[-1]
            dest_csv = staging_dir / file_name
            normalize_source_csv(source_csv, dest_csv)
            manifest_entries.append(
                {
                    "status": "ready",
                    "result_id": source_csv.name,
                    "csv": str(dest_csv),
                    "s3_key": s3_key,
                    "auto_assessment_mapping": auto_assessment_mapping,
                }
            )
            counts["uploaded"] += 1
        except (KeyError, ValueError, OSError) as exc:
            counts["failed"] += 1
            manifest_entries.append(
                {
                    "status": "failed",
                    "reason": str(exc),
                    "result_id": source_csv.name,
                }
            )

    print(
        json.dumps(
            {
                "source": "source_dir",
                "counts": counts,
                "entries": manifest_entries,
            }
        )
    )
    return manifest_entries


def pi_correct_answer(question: dict[str, Any]) -> str:
    options = question.get("options") or []
    idx = question.get("correctAnswerIndex")
    if isinstance(idx, int) and isinstance(options, list) and 0 <= idx < len(options):
        return str(options[idx]).strip()
    return "-"


def subject_name_from_assessment(assessment: dict[str, Any]) -> tuple[str, str]:
    """Return (subject_name, module_name) using Pi category, then module, then title."""
    module = assessment.get("module") if isinstance(assessment.get("module"), dict) else {}
    module_name = str(module.get("name") or "").strip()
    categories = module.get("categories")
    if isinstance(categories, list):
        category_names = [
            str(item.get("name") or "").strip()
            for item in categories
            if isinstance(item, dict) and str(item.get("name") or "").strip()
        ]
        if category_names:
            return category_names[0], module_name
    if module_name:
        return module_name, module_name
    title = str(assessment.get("title") or "").strip()
    if title:
        return title, module_name
    return "General", module_name


def write_subject_meta_json(
    path: Path,
    *,
    subject_name: str,
    module_name: str = "",
    assessment_name: str = "",
) -> None:
    payload = {
        "subjectName": subject_name,
        "moduleName": module_name,
        "assessmentName": assessment_name,
        "source": "pi-sync",
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_marking_scheme_csv(path: Path, questions: list[dict[str, Any]]) -> None:
    headers: list[str] = []
    answers: list[str] = []
    for idx, question in enumerate(questions):
        prompt = str(question.get("prompt") or "").strip() or f"Question {idx + 1}"
        headers.append(prompt)
        answers.append(pi_correct_answer(question))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(headers)
        writer.writerow(answers)
    validate_csv_file(path)


def process_marking_schemes(
    payload: dict[str, Any],
    *,
    assessment_index: dict[str, dict[str, str]],
    default_parent_org: str,
    staging_dir: Path,
) -> list[dict[str, Any]]:
    questions_by_assessment = payload.get("questionsByAssessmentId") or {}
    results = payload.get("data") or []
    if not isinstance(questions_by_assessment, dict):
        print(
            json.dumps(
                {
                    "source": "marking-schemes",
                    "counts": {"ready": 0, "failed": 0},
                    "entries": [],
                    "warning": "questionsByAssessmentId is missing or invalid; result CSVs will still be exported",
                }
            )
        )
        return []

    title_by_pi_id: dict[str, str] = {}
    subject_by_pi_id: dict[str, str] = {}
    module_by_pi_id: dict[str, str] = {}
    for result in results:
        if not isinstance(result, dict):
            continue
        assessment = result.get("assessment") or {}
        if not isinstance(assessment, dict):
            assessment = {}
        pi_assessment_id = str(result.get("assessmentId") or assessment.get("id") or "").strip()
        assessment_title = str(assessment.get("title") or "").strip()
        if pi_assessment_id and assessment_title and pi_assessment_id not in title_by_pi_id:
            title_by_pi_id[pi_assessment_id] = assessment_title
        if pi_assessment_id and pi_assessment_id not in subject_by_pi_id:
            subject_name, module_name = subject_name_from_assessment(assessment)
            subject_by_pi_id[pi_assessment_id] = subject_name
            module_by_pi_id[pi_assessment_id] = module_name

    manifest_entries: list[dict[str, Any]] = []
    counts = {"ready": 0, "failed": 0}

    for pi_assessment_id, questions in questions_by_assessment.items():
        if not isinstance(questions, list) or not questions:
            continue
        assessment_title = title_by_pi_id.get(pi_assessment_id, pi_assessment_id)
        try:
            cloud_assessment_id, parent_org, auto_assessment_mapping = resolve_assessment_mapping(
                assessment_index,
                default_parent_org,
                assessment_id=pi_assessment_id,
                assessment_title=assessment_title,
            )
            parent_org = parent_org or default_parent_org
            csv_path = staging_dir / f"marking-scheme-{cloud_assessment_id}.csv"
            write_marking_scheme_csv(csv_path, questions)
            subject_name = subject_by_pi_id.get(pi_assessment_id, "General")
            module_name = module_by_pi_id.get(pi_assessment_id, "")
            subject_json_path = staging_dir / f"marking-scheme-{cloud_assessment_id}.subject.json"
            write_subject_meta_json(
                subject_json_path,
                subject_name=subject_name,
                module_name=module_name,
                assessment_name=assessment_title,
            )
            scheme_prefix = (
                f"{normalize_key_segment(parent_org)}/MarkingSchemes/"
                f"{normalize_key_segment(cloud_assessment_id)}"
            )
            s3_key = f"{scheme_prefix}/pi-sync-marking-scheme.csv"
            subject_s3_key = f"{scheme_prefix}/pi-sync-subject.json"
            manifest_entries.append(
                {
                    "status": "ready",
                    "kind": "marking-scheme",
                    "pi_assessment_id": pi_assessment_id,
                    "assessment_id": cloud_assessment_id,
                    "assessment_name": assessment_title,
                    "subject_name": subject_name,
                    "module_name": module_name,
                    "auto_assessment_mapping": auto_assessment_mapping,
                    "csv": str(csv_path),
                    "s3_key": s3_key,
                    "subject_json": str(subject_json_path),
                    "subject_s3_key": subject_s3_key,
                }
            )
            counts["ready"] += 1
        except (KeyError, ValueError) as exc:
            counts["failed"] += 1
            manifest_entries.append(
                {
                    "status": "failed",
                    "kind": "marking-scheme",
                    "pi_assessment_id": pi_assessment_id,
                    "reason": str(exc),
                }
            )

    print(json.dumps({"source": "marking-schemes", "counts": counts, "entries": manifest_entries}))
    return manifest_entries


def write_manifest(staging_dir: Path, entries: list[dict[str, Any]]) -> Path:
    manifest_path = staging_dir / "manifest.json"
    ready = [
        entry
        for entry in entries
        if entry.get("status") == "ready" and entry.get("kind") != "marking-scheme"
    ]
    marking_schemes = [
        entry
        for entry in entries
        if entry.get("status") == "ready" and entry.get("kind") == "marking-scheme"
    ]
    failed = [entry for entry in entries if entry.get("status") == "failed"]
    skipped = [entry for entry in entries if entry.get("status") == "skipped"]
    payload = {
        "generatedAt": utc_now_iso(),
        "ready": ready,
        "marking_schemes": marking_schemes,
        "failed": failed,
        "skipped": skipped,
        "counts": {
            "ready": len(ready),
            "marking_schemes": len(marking_schemes),
            "failed": len(failed),
            "skipped": len(skipped),
        },
    }
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def main() -> int:
    project_root = Path(__file__).resolve().parents[4]
    data_dir = project_root / "00_DATA"
    assessments_root = data_dir / "00_OC4D_ASSESSMENTS"
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    staging_dir = assessments_root / f"staging_{stamp}"
    staging_dir.mkdir(parents=True, exist_ok=True)

    default_parent_org = os.environ.get("OC4D_PARENT_ORG", "Home-Schooling").strip()
    unassigned_student_id = os.environ.get("OC4D_UNASSIGNED_STUDENT_ID", "unassigned").strip() or "unassigned"
    student_map = Path(
        os.environ.get(
            "OC4D_STUDENT_MAP_FILE",
            str(project_root / "config/oc4d/student-map.csv"),
        )
    )
    assessment_map = Path(
        os.environ.get(
            "OC4D_ASSESSMENT_MAP_FILE",
            str(project_root / "config/oc4d/assessment-map.csv"),
        )
    )
    state_file = Path(
        os.environ.get(
            "OC4D_STATE_FILE",
            str(assessments_root / "uploaded-state.json"),
        )
    )
    source_dir = os.environ.get("OC4D_SOURCE_DIR", "").strip()
    api_base = os.environ.get("OC4D_API_BASE_URL", "http://127.0.0.1:3000").strip()
    api_token = os.environ.get("OC4D_API_TOKEN", "").strip()
    api_take = int(os.environ.get("OC4D_API_TAKE", "2000"))
    oc4d_bucket = os.environ.get("OC4D_BUCKET", "").strip()

    local_student_rows = load_mapping_file(
        student_map,
        ("source_student_name", "studentId", "parentOrg"),
        missing_ok=True,
    )
    cloud_student_rows = load_cloud_student_rows(default_parent_org)
    assessment_rows = load_mapping_file(
        assessment_map,
        ("source_assessment_name", "assessmentId", "parentOrg"),
    )
    # Cloud roster rows are loaded first so the local CSV can override them.
    student_index = index_mapping(cloud_student_rows + local_student_rows, "source_student_name")
    cloud_student_ids = load_cloud_student_prefix_ids(
        oc4d_bucket,
        default_parent_org,
        unassigned_student_id,
    )
    if cloud_student_rows or cloud_student_ids:
        print(
            json.dumps(
                {
                    "source": "student-map",
                    "cloud_rows": len(cloud_student_rows),
                    "local_rows": len(local_student_rows),
                    "cloud_prefix_ids": len(cloud_student_ids),
                }
            )
        )
    assessment_index = index_mapping(assessment_rows, "source_assessment_name")
    uploaded_ids = load_state(state_file)

    all_entries: list[dict[str, Any]] = []

    if source_dir:
        source_path = Path(source_dir)
        if source_path.is_dir():
            all_entries.extend(
                process_source_dir(
                    source_path,
                    student_index=student_index,
                    assessment_index=assessment_index,
                    default_parent_org=default_parent_org,
                    staging_dir=staging_dir,
                )
            )

    try:
        payload = fetch_api_payload(api_base, api_token, api_take)
        all_entries.extend(
            process_marking_schemes(
                payload,
                assessment_index=assessment_index,
                default_parent_org=default_parent_org,
                staging_dir=staging_dir,
            )
        )
        api_entries, _ = process_api_results(
            payload,
            student_index=student_index,
            cloud_student_ids=cloud_student_ids,
            assessment_index=assessment_index,
            default_parent_org=default_parent_org,
            unassigned_student_id=unassigned_student_id,
            staging_dir=staging_dir,
            uploaded_ids=uploaded_ids,
        )
        all_entries.extend(api_entries)
    except RuntimeError as exc:
        if not source_dir:
            print(json.dumps({"error": str(exc), "counts": {"failed": 1}}))
            return 1
        print(json.dumps({"warn": str(exc), "source": "api"}))

    manifest_path = write_manifest(staging_dir, all_entries)
    print(json.dumps({"manifest": str(manifest_path), "staging_dir": str(staging_dir)}))
    ready_count = sum(1 for entry in all_entries if entry.get("status") == "ready")
    failed_count = sum(1 for entry in all_entries if entry.get("status") == "failed")
    if ready_count == 0 and failed_count > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
