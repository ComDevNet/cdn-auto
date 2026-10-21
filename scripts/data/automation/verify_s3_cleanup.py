import hashlib
import json
import os
from pathlib import Path
import sys
import time
import subprocess
import tempfile
from datetime import datetime, timezone


class AwsCliError(Exception):
    def __init__(self, code):
        self.response = {'Error': {'Code': code}}
        super().__init__(code)


class PipeBody:
    def __init__(self, process, reader, errors):
        self.process, self.reader, self.errors = process, reader, errors

    def read(self, size):
        return self.reader.read(size)

    def close(self):
        self.reader.close()
        try:
            status = self.process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AwsCliError('DownloadTimeout')
        finally:
            self.errors.close()
        if status:
            raise AwsCliError('DownloadFailed')


class AwsCliClient:
    def __init__(self):
        self.command = ['aws', '--region', os.environ.get('AWS_REGION') or 'us-east-1',
                        '--cli-connect-timeout', '10', '--cli-read-timeout', '30', 's3api']

    def head_object(self, Bucket, Key):
        result = subprocess.run(self.command + ['head-object', '--bucket', Bucket, '--key', Key,
                                '--output', 'json'], capture_output=True, timeout=90)
        if result.returncode:
            code = 'NoSuchKey' if b'404' in result.stderr or b'NoSuchKey' in result.stderr else 'HeadFailed'
            raise AwsCliError(code)
        return json.loads(result.stdout)

    def get_object(self, Bucket, Key, IfMatch, VersionId=None):
        read_fd, write_fd = os.pipe()
        errors = tempfile.TemporaryFile()
        command = self.command + ['get-object', '--bucket', Bucket, '--key', Key, '--if-match', IfMatch]
        if VersionId:
            command += ['--version-id', VersionId]
        command += [f'/proc/self/fd/{write_fd}']
        try:
            process = subprocess.Popen(command, pass_fds=(write_fd,), stdout=subprocess.DEVNULL, stderr=errors)
        except Exception:
            os.close(read_fd)
            errors.close()
            raise
        finally:
            os.close(write_fd)
        return {'Body': PipeBody(process, os.fdopen(read_fd, 'rb'), errors)}


def fingerprint(path):
    stat = path.stat()
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns


def hash_stream(stream, bytes_per_second=None):
    digest = hashlib.sha256()
    started, count = time.monotonic(), 0
    while block := stream.read(1024 * 1024):
        digest.update(block)
        count += len(block)
        if bytes_per_second:
            time.sleep(max(0, count / bytes_per_second - (time.monotonic() - started)))
    return digest.hexdigest()


def verify(client, path, bucket, key, cache):
    if path.is_symlink() or not path.is_file():
        return {'status': 'retained_unsafe_path'}
    before = fingerprint(path)
    try:
        head = client.head_object(Bucket=bucket, Key=key)
        if head['ContentLength'] != before[2]:
            return {'status': 'retained_size_mismatch', 'cloud_bytes': head['ContentLength']}
        identity = bucket, key, head['ETag']
        if identity not in cache:
            kwargs = dict(Bucket=bucket, Key=key, IfMatch=head['ETag'])
            if head.get('VersionId'):
                kwargs['VersionId'] = head['VersionId']
            response = client.get_object(**kwargs)
            body = response['Body']
            try:
                cache[identity] = hash_stream(body, 256 * 1024)
            finally:
                body.close()
        with path.open('rb') as source:
            local_hash = hash_stream(source)
        if fingerprint(path) != before:
            return {'status': 'retained_changed_during_verification'}
        if local_hash != cache[identity]:
            return {'status': 'retained_hash_mismatch'}
        return {'status': 'verified', 'sha256': local_hash, 'etag': head['ETag'],
                'version_id': head.get('VersionId'), 'fingerprint': before}
    except Exception as error:
        code = getattr(error, 'response', {}).get('Error', {}).get('Code', type(error).__name__)
        return {'status': 'retained_verification_error', 'error_code': str(code)}


def remove_verified(root, path, result, is_queue, bucket, key):
    import fcntl
    lock_path = root / '00_UPLOAD_QUEUE' / '.automation.lock'
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 'retained_queue_busy'
        try:
            if path.is_symlink() or not path.resolve().is_relative_to(root):
                return 'retained_unsafe_path'
            if fingerprint(path) != tuple(result['fingerprint']):
                return 'retained_changed_before_delete'
            if is_queue and path.parent.name == 'uploading':
                return 'retained_active_upload'
            if is_queue and path.parent.parent.name == 'OC4DAssessments':
                sidecar = Path(str(path) + '.oc4dkey')
                lines = sidecar.read_text().splitlines()
                if not lines or lines[0] != key:
                    return 'retained_changed_sidecar'
                version = lines[2] if len(lines) > 2 else ''
                receipt = path.parent.parent / 'completed' / (path.name + '.s3receipt')
                receipt.parent.mkdir(exist_ok=True)
                temporary = Path(str(receipt) + '.tmp')
                temporary.write_text('\n'.join((result['sha256'], key, version, bucket)) + '\n')
                temporary.replace(receipt)
            path.unlink()
            if is_queue:
                for suffix in ('.cdnrun', '.oc4dkey'):
                    sidecar = Path(str(path) + suffix)
                    if sidecar.is_file() and not sidecar.is_symlink():
                        sidecar.unlink()
            return 'deleted_verified'
        except FileNotFoundError:
            return 'retained_moved_during_verification'


def main():
    root = Path('/home/pi/cdn-auto/00_DATA').resolve()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    audit_path = Path('/home/pi/cdn-auto-backups') / f's3-verified-cleanup-{stamp}.jsonl'
    audit_path.parent.mkdir(exist_ok=True)
    bucket_path = os.environ['S3_BUCKET'].removeprefix('s3://').strip('/')
    bucket, _, bucket_prefix = bucket_path.partition('/')
    prefix = '/'.join(x.strip('/') for x in (bucket_prefix, os.environ.get('S3_SUBFOLDER', '')) if x)
    client = AwsCliClient()
    candidates = []
    for stage in ('RACHEL', 'ModuleGaze', 'OC4DAssessments'):
        for state in ('completed', 'pending', 'failed'):
            folder = root / '00_UPLOAD_QUEUE' / stage / state
            for path in sorted(folder.glob('*')):
                if path.suffix not in ('.csv', '.json') or path.is_symlink():
                    continue
                if stage == 'OC4DAssessments':
                    sidecar = Path(str(path) + '.oc4dkey')
                    if not sidecar.is_file():
                        continue
                    key = sidecar.read_text().splitlines()[0]
                    dest_bucket = os.environ.get('OC4D_BUCKET', 'oc4d-raw-reports').removeprefix('s3://').strip('/')
                else:
                    extra = os.environ.get('RACHEL_SUBFOLDER' if stage == 'RACHEL' else 'MODULEGAZE_SUBFOLDER', '')
                    key = '/'.join(x.strip('/') for x in (prefix, stage, extra, path.name) if x)
                    dest_bucket = bucket
                candidates.append((path, dest_bucket, key, True))
    for path in sorted((root / '00_PROCESSED').glob('*/*.csv')):
        if path.name.endswith('_access_logs.csv'):
            stage, extra = 'RACHEL', os.environ.get('RACHEL_SUBFOLDER', '')
        elif path.name.endswith('_modulegaze_logs.csv'):
            stage, extra = 'ModuleGaze', os.environ.get('MODULEGAZE_SUBFOLDER', '')
        else:
            continue
        key = '/'.join(x.strip('/') for x in (prefix, stage, extra, path.name) if x)
        candidates.append((path, bucket, key, False))
    print(f'AUDIT {audit_path}; candidates={len(candidates)}', flush=True)
    counts, freed, cache = {}, 0, {}
    with audit_path.open('x', encoding='utf-8') as audit:
        def record(entry):
            audit.write(json.dumps(entry) + '\n')
            audit.flush()
            os.fsync(audit.fileno())
        for index, (path, dest_bucket, key, is_queue) in enumerate(candidates, 1):
            if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
                continue
            size = path.stat().st_size
            result = verify(client, path, dest_bucket, key, cache)
            entry = dict(path=str(path), bytes=size, s3=f's3://{dest_bucket}/{key}', **result)
            if result['status'] == 'verified':
                # Persist the verified cloud identity before any local deletion.
                record(dict(entry, action='delete_authorized'))
                entry['status'] = remove_verified(root, path, result, is_queue, dest_bucket, key)
                if entry['status'] == 'deleted_verified':
                    freed += size
            record(entry)
            status = entry['status']
            counts[status] = counts.get(status, 0) + 1
            if status == 'deleted_verified' or index % 25 == 0:
                print(f'{index}/{len(candidates)} {status} bytes={size} {path.name}', flush=True)
        record(dict(summary=counts, bytes_freed=freed))
    print(json.dumps(dict(summary=counts, bytes_freed=freed, audit=str(audit_path))), flush=True)


if __name__ == '__main__':
    main()
