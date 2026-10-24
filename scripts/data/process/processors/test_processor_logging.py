import contextlib
import csv
import importlib.util
import io
import json
import runpy
import sys
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class ProcessorLoggingTests(unittest.TestCase):
    def test_repeated_harvest_does_not_reimport_exports_or_stale_files(self):
        for filename in ('log-v6.py', 'logv2.py', 'dhub.py'):
            with self.subTest(processor=filename), tempfile.TemporaryDirectory() as tmp:
                script = Path(__file__).with_name(filename).resolve()
                run_name = 'site_logs_2026_10_21'
                raw = Path(tmp) / '00_DATA' / run_name
                processed = Path(tmp) / '00_DATA' / '00_PROCESSED' / run_name
                raw.mkdir(parents=True)
                processed.mkdir(parents=True)
                access = ('192.168.4.2 - [2026-10-21T12:34:56.123Z] '
                          '"GET /modules/id/lesson HTTP/1.1" 200 1024 "-" "test-agent"')
                source = raw / 'oc4d-test.log'
                source.write_text(json.dumps({'message': access}) + '\n', encoding='utf-8')
                fake_ua = SimpleNamespace(parse=lambda _: SimpleNamespace(
                    os=SimpleNamespace(family='Linux'), browser=SimpleNamespace(family='Firefox')))
                with patch.dict('sys.modules', {'user_agents': fake_ua}), contextlib.chdir(tmp):
                    for _ in range(3):
                        with patch.object(sys, 'argv', [str(script), run_name]), contextlib.redirect_stdout(io.StringIO()):
                            runpy.run_path(str(script), run_name='__main__')
                        rows = list(csv.reader(io.StringIO((processed / 'summary.csv').read_text(encoding='utf-8'))))
                        self.assertEqual(len(rows), 2, filename)
                        (processed / 'site_nr_20261021_1230_900s_access_logs.csv').write_text(
                            (processed / 'summary.csv').read_text(encoding='utf-8'), encoding='utf-8')
                    # A file with no access entries must not reuse its previous CSV.
                    source.write_text(json.dumps({'message': 'no accesses'}) + '\n', encoding='utf-8')
                    with patch.object(sys, 'argv', [str(script), run_name]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        runpy.run_path(str(script), run_name='__main__')
                    rows = list(csv.reader(io.StringIO((processed / 'summary.csv').read_text(encoding='utf-8'))))
                    self.assertEqual(len(rows), 1, filename)

    def test_modulegaze_create_master_uses_explicit_paths_only(self):
        """Belt-and-suspenders: even if a filtered export sits in the folder, it is ignored."""
        spec = importlib.util.spec_from_file_location(
            'modulegaze', Path(__file__).with_name('modulegaze.py'))
        modulegaze = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(modulegaze)
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            real = folder / 'modulegaze-sessions.csv'
            export = folder / 'site_nr_20261021_1230_900s_modulegaze_logs.csv'
            header = ','.join(modulegaze.HEADER)
            real.write_text(header + '\nGuest,12:00:00,192.168.4.2,2026-10-21,mod-1,10\n', encoding='utf-8')
            export.write_text(
                header + '\n' + ('Guest,12:00:00,192.168.4.2,2026-10-21,mod-1,10\n' * 50),
                encoding='utf-8')
            modulegaze.create_master_csv(str(folder), [str(real)])
            rows = list(csv.reader(io.StringIO((folder / 'summary.csv').read_text(encoding='utf-8'))))
            self.assertEqual(len(rows), 2, 'filtered export must not be merged into summary')

    def test_noisy_input_has_bounded_output_and_keeps_access_rows(self):
        for filename in ('log-v6.py', 'logv2.py'):
            with self.subTest(processor=filename), tempfile.TemporaryDirectory() as tmp:
                spec = importlib.util.spec_from_file_location('processor', Path(__file__).with_name(filename))
                processor = importlib.util.module_from_spec(spec)
                # UA classification is unrelated to log volume and has its own dependency.
                fake_ua = SimpleNamespace(parse=lambda _: SimpleNamespace(
                    os=SimpleNamespace(family='Linux'), browser=SimpleNamespace(family='Firefox')))
                with patch.dict('sys.modules', {'user_agents': fake_ua}):
                    spec.loader.exec_module(processor)
                access = ('192.168.4.2 - [2026-10-21T12:34:56.123Z] '
                          '"GET /modules/id/lesson HTTP/1.1" 200 1024 "-" "test-agent"')
                source = Path(tmp) / 'oc4d-test.log'
                source.write_text(
                    (json.dumps({'message': 'captive portal ignored'}) + '\n') * 10000
                    + 'malformed record\n'
                    + json.dumps({'message': access}) + '\n', encoding='utf-8')
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    rows = processor.process_log_file(source)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0][0], '192.168.4.2')
                self.assertEqual(rows[0][1], '2026-10-21')
                self.assertEqual(stdout.getvalue(), '')
                self.assertIn('ignored 10000 non-access lines; 1 malformed lines', stderr.getvalue())
                self.assertLess(len(stderr.getvalue()), 200)


if __name__ == '__main__':
    unittest.main()
