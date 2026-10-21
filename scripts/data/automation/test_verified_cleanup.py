import io
import tempfile
from pathlib import Path
import unittest
import sys
sys.path.insert(0, str(Path(__file__).parent))
from verify_s3_cleanup import verify, remove_verified


class Cloud:
    def __init__(self, body): self.body = body
    def head_object(self, **kwargs): return {'ContentLength': len(self.body), 'ETag': 'version-one'}
    def get_object(self, **kwargs):
        assert kwargs['IfMatch'] == 'version-one'
        return {'Body': io.BytesIO(self.body)}


class VerifiedCleanupTests(unittest.TestCase):
    def test_hash_mismatch_and_missing_cloud_copy_preserve_local_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'payload.csv'
            path.write_bytes(b'local data')
            self.assertEqual(verify(Cloud(b'other data'), path, 'bucket', 'key', {})['status'], 'retained_hash_mismatch')
            class Missing(Cloud):
                def head_object(self, **kwargs): raise FileNotFoundError()
            self.assertEqual(verify(Missing(b''), path, 'bucket', 'key', {})['status'], 'retained_verification_error')
            self.assertEqual(path.read_bytes(), b'local data')

    @unittest.skipIf(sys.platform == 'win32', 'Linux queue locking')
    def test_cleanup_yields_to_uploader_and_rechecks_the_file(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / '00_UPLOAD_QUEUE' / 'RACHEL' / 'pending' / 'file.csv'
            path.parent.mkdir(parents=True)
            path.write_bytes(b'local data')
            result = verify(Cloud(b'local data'), path, 'bucket', 'key', {})
            lock_path = root / '00_UPLOAD_QUEUE' / '.automation.lock'
            with lock_path.open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(remove_verified(root, path, result, True, 'bucket', 'key'), 'retained_queue_busy')
                self.assertTrue(path.exists())
            path.write_bytes(b'changed data')
            self.assertEqual(remove_verified(root, path, result, True, 'bucket', 'key'), 'retained_changed_before_delete')
            result = verify(Cloud(b'changed data'), path, 'bucket', 'key', {})
            self.assertEqual(remove_verified(root, path, result, True, 'bucket', 'key'), 'deleted_verified')
            self.assertFalse(path.exists())

    @unittest.skipIf(sys.platform == 'win32', 'Linux queue locking')
    def test_verified_assessment_keeps_receipt_and_changed_key_is_retained(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / '00_UPLOAD_QUEUE' / 'OC4DAssessments' / 'completed' / 'scheme.csv'
            path.parent.mkdir(parents=True)
            path.write_bytes(b'assessment')
            sidecar = Path(str(path) + '.oc4dkey')
            sidecar.write_text('expected-key\n\n2\n')
            result = verify(Cloud(b'assessment'), path, 'bucket', 'expected-key', {})
            self.assertEqual(remove_verified(root, path, result, True, 'bucket', 'changed-key'), 'retained_changed_sidecar')
            self.assertTrue(path.exists())
            self.assertEqual(remove_verified(root, path, result, True, 'bucket', 'expected-key'), 'deleted_verified')
            receipt = Path(str(path) + '.s3receipt').read_text().splitlines()
            self.assertEqual(receipt[1:], ['expected-key', '2', 'bucket'])
            self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()
