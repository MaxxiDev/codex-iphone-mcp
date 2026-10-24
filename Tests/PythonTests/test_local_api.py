import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('local_api', ROOT / 'scripts/local_api.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class LocalAPITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.token = Path(self.directory.name) / 'api-token'
        self.token.write_text('a' * 64 + '\n')
        self.token.chmod(0o600)
        patcher = patch.dict(os.environ, IPHONE_USE_AUTH_FILE=str(self.token))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_authenticates_get_and_post_without_exposing_token_in_url(self):
        for data in (None, b'{"text":"hello"}'):
            request = api.authenticated_request('http://127.0.0.1:7390/type', data)
            self.assertEqual(request.get_header('Authorization'), 'Bearer ' + 'a' * 64)
            self.assertEqual(request.get_header('Content-type'), 'application/json')
            self.assertNotIn('a' * 64, request.full_url)
            self.assertEqual(request.data, data)

    def test_refuses_remote_urls_before_reading_token(self):
        for url in ('https://evil.example/', 'http://evil.example:7390/',
                    'http://127.0.0.1/', 'http://user:pass@127.0.0.1:7390/'):
            with patch.object(api, 'read_token') as read:
                with self.assertRaises(ValueError):
                    api.authenticated_request(url)
                read.assert_not_called()

    def test_refuses_loose_permissions_and_symlinks(self):
        self.token.chmod(0o644)
        with self.assertRaises(ValueError):
            api.read_token()
        self.token.chmod(0o600)
        link = self.token.with_name('link')
        link.symlink_to(self.token)
        with patch.dict(os.environ, IPHONE_USE_AUTH_FILE=str(link)):
            with self.assertRaises(OSError):
                api.read_token()

    def test_refuses_malformed_tokens(self):
        self.token.write_text('not-a-token\n')
        with self.assertRaises(ValueError):
            api.read_token()

    def test_never_redirects_credentials(self):
        with self.assertRaises(ValueError):
            api.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://evil.example')


if __name__ == '__main__':
    unittest.main()
