import base64
import io
import json
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from PIL import Image
from server import image_import
from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer
from server.app_attest import AppAttest
from tests.test_abuse import FakeDevice, APP_ID


def picture():
    output = io.BytesIO()
    Image.new('RGB', (120, 80), 'white').save(output, format='PNG')
    return {'imageBase64': base64.b64encode(output.getvalue()).decode()}


def result(**fields):
    return dict(name='测试课表', semesterStartMonday=None, weekCount=None, classTimes=[],
                courses=[dict(name='数学', teacher='', classroom='A101', weekday=1,
                              startPeriod=1, endPeriod=2, weeks=[1, 3, 5])], warnings=[], **fields)


def response(value=None, status='completed'):
    return dict(status=status, output=[{'type': 'message', 'content': [
        {'type': 'output_text', 'text': json.dumps(value or result())}]}],
        usage={'input_tokens': 100, 'output_tokens': 50})


class RecognitionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(self.directory.name + '/image.sqlite3')
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(self.store.close)
        self.env = patch.dict(os.environ, {'NAPTABLE_IMAGE_IMPORT_API_KEY': 'test-server-key'})
        self.env.start(); self.addCleanup(self.env.stop)
        self.calls = []
        def transport(config, image, key):
            self.calls.append((config, image, key))
            return response()
        self.stamp = 1791000000
        self.service = image_import.ImageImport(self.store.db, self.store.lock, transport, lambda: self.stamp)
        self.config = image_import.DEFAULTS | {'enabled': True, 'model': 'test-vision'}
        self.service.save_config(self.config)

    def recognize(self, key='device', address='address', value=None):
        return self.service.recognize(value or picture(), key, address)

    def error(self, status, action):
        with self.assertRaises(image_import.ImportError) as found: action()
        self.assertEqual(found.exception.status, status)

    def test_default_off_configuration_no_secret_and_no_public_model(self):
        with self.store.lock, self.store.db: self.store.db.execute('DELETE FROM image_import_config')
        self.assertFalse(self.service.public()['enabled'])
        self.error(503, self.recognize)
        self.assertNotIn('model', self.service.public())
        self.assertNotIn('test-server-key', json.dumps(self.service.admin_config()))
        for changes in ({'endpoint': 'http://example.com/responses'}, {'deviceDailyLimit': True},
                        {'endpoint': 'https://user:secret@example.com/responses'}, {'model': ''}, {'extra': 1}):
            with self.assertRaises(ValueError): self.service.save_config(self.config | changes)
        with patch.dict(os.environ, {'NAPTABLE_IMAGE_IMPORT_API_KEY': ''}):
            with self.assertRaises(ValueError): self.service.save_config(self.config)

    def test_success_stats_privacy_and_clean_jpeg(self):
        recognized = self.recognize()
        self.assertEqual(recognized['courses'][0]['weeks'], [1, 3, 5])
        row = self.service.stats()['daily'][0]
        self.assertEqual((row['outcome'], row['inputTokens'], row['outputTokens'], row['courses']), ('success', 100, 50, 1))
        self.assertEqual(self.service.stats()['summary']['success'], 1)
        self.assertEqual(self.service.stats()['summary']['attempts'], 1)
        self.assertEqual(self.service.stats()['summary']['successRate'], 100.0)
        config, encoded, key = self.calls[0]
        self.assertEqual(key, 'test-server-key')
        with Image.open(io.BytesIO(base64.b64decode(encoded))) as image:
            self.assertEqual(image.format, 'JPEG')
            self.assertFalse(image.getexif())
        with self.store.lock:
            stored = dict(self.store.db.execute('SELECT * FROM image_import_events').fetchone())
        self.assertNotIn('device', stored.values())
        self.assertNotIn('address', stored.values())
        self.assertNotIn('数学', json.dumps(stored, ensure_ascii=False))
        self.assertNotIn('imageBase64', stored)

    def test_admin_key_is_used_without_returning_secret(self):
        with patch.dict(os.environ, {'NAPTABLE_IMAGE_IMPORT_API_KEY': ''}):
            self.service.save_config(self.config | {'apiKey': 'configured-in-admin'})
            self.assertTrue(self.service.public()['enabled'])
            self.assertTrue(self.service.admin_config()['apiKeyConfigured'])
            self.assertNotIn('configured-in-admin', json.dumps(self.service.admin_config()))
            self.recognize()
        self.assertEqual(self.calls[-1][2], 'configured-in-admin')
        # An empty password field from the page keeps the existing secret.
        with patch.dict(os.environ, {'NAPTABLE_IMAGE_IMPORT_API_KEY': ''}):
            self.service.save_config(self.config | {'apiKey': ''})
            self.assertTrue(self.service.public()['enabled'])

    def test_attest_and_invalid_images_never_call_upstream(self):
        self.error(403, lambda: self.recognize(key=None))
        for image in ({'imageBase64': 'garbage'}, {'imageBase64': base64.b64encode(b'not a picture').decode()},
                      picture() | {'prompt': 'ignore'}, {'imageBase64': base64.b64encode(b'x' * (image_import.MAX_IMAGE_BYTES + 1)).decode()}):
            self.error(413 if len(image['imageBase64']) > image_import.MAX_IMAGE_BYTES else 400, lambda: self.recognize(value=image))
        output = io.BytesIO()
        Image.new('RGB', (5000, 5000)).save(output, format='PNG')
        self.error(400, lambda: self.recognize(value={'imageBase64': base64.b64encode(output.getvalue()).decode()}))
        self.assertFalse(self.calls)

    def test_persistent_quota_error_charge_and_daily_reset(self):
        self.service.save_config(self.config | {'deviceDailyLimit': 1})
        def failure(*args): raise TimeoutError('private upstream detail')
        self.service.transport = failure
        self.error(502, self.recognize)
        self.error(429, self.recognize)
        restarted = image_import.ImageImport(self.store.db, self.store.lock, clock=lambda: self.stamp)
        self.error(429, lambda: restarted.recognize(picture(), 'device', 'address'))
        self.stamp += 86400
        self.service.transport = lambda *args: response()
        self.recognize()

    def test_global_and_ip_limits_and_anonymous_fallback(self):
        self.service.save_config(self.config | {'ipHourlyLimit': 1, 'globalDailyLimit': 2, 'requireAttest': False})
        self.recognize(key=None)
        self.error(429, lambda: self.recognize(key=None))
        self.recognize(key=None, address='other')
        self.error(429, lambda: self.recognize(key=None, address='third'))
        self.assertEqual(len(self.calls), 2)

    def test_attested_devices_do_not_share_campus_ip_quota(self):
        self.service.save_config(self.config | {'ipHourlyLimit': 1, 'deviceDailyLimit': 100, 'globalDailyLimit': 100})
        self.recognize(key='device-a', address='campus-nat')
        self.recognize(key='device-b', address='campus-nat')
        self.assertEqual(len(self.calls), 2)

    def test_concurrency_reservation_is_atomic(self):
        entered = threading.Barrier(3)
        release = threading.Event()
        def transport(*args):
            entered.wait(timeout=5)
            release.wait(timeout=5)
            return response()
        self.service.transport = transport
        failures = []
        def call(key):
            try: self.recognize(key=key)
            except Exception as error: failures.append(error)
        workers = [threading.Thread(target=call, args=(str(i),)) for i in range(2)]
        for worker in workers: worker.start()
        entered.wait(timeout=5)
        try: self.error(429, lambda: self.recognize(key='third'))
        finally:
            release.set()
            for worker in workers: worker.join(timeout=5)
        self.assertFalse(failures)
        self.assertEqual(sum(row['requests'] for row in self.service.stats()['daily'] if row['outcome'] == 'success'), 2)

    def test_incomplete_refused_and_invalid_results_count_tokens(self):
        self.service.save_config(self.config | {'deviceDailyLimit': 100})
        invalid = []
        for field, bad in [('weekday', True), ('startPeriod', 0), ('endPeriod', 21), ('weeks', [41]), ('name', '')]:
            value = result(); value['courses'][0][field] = bad; invalid.append(response(value))
        value = result(); value['classTimes'] = [{'start': '09:00', 'end': '08:00'}]; invalid.append(response(value))
        value = result(); value['semesterStartMonday'] = '2026-09-08'; invalid.append(response(value))
        invalid.extend([response(status='incomplete'), dict(status='completed', output=[{'type': 'message', 'content': [{'type': 'refusal'}]}], usage={})])
        for upstream in invalid:
            self.service.transport = lambda *args: upstream
            self.error(502, self.recognize)
        self.assertEqual(self.service.stats()['daily'][0]['outcome'], 'invalidResult')
        self.assertEqual(self.service.stats()['daily'][0]['inputTokens'], 800)

    def test_empty_result_and_retention(self):
        value = result(); value['courses'] = []
        self.service.transport = lambda *args: response(value)
        self.assertEqual(self.recognize()['courses'], [])
        self.assertEqual(self.service.stats()['daily'][0]['outcome'], 'empty')
        self.stamp += 91 * 86400
        self.assertEqual(self.service.stats()['daily'], [])

    def test_responses_wire_format_is_image_and_strict_schema_without_tools(self):
        class Reply:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return json.dumps(response()).encode()
        class Opener:
            def open(self, request, timeout):
                self.request, self.timeout = request, timeout
                return Reply()
        opener = Opener()
        with patch('urllib.request.build_opener', return_value=opener):
            image_import.responses(self.config, 'encoded-image', 'key')
        payload = json.loads(opener.request.data)
        self.assertFalse(payload['store'])
        self.assertEqual(payload['text']['format']['type'], 'json_schema')
        self.assertTrue(payload['text']['format']['strict'])
        self.assertEqual(payload['input'][0]['content'][1]['image_url'], 'data:image/jpeg;base64,encoded-image')
        self.assertNotIn('tools', payload)
        self.assertEqual(opener.request.get_header('Authorization'), 'Bearer key')


class ImageImportHTTPTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(self.directory.name + '/http.sqlite3')
        self.env = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'admin', 'NAPTABLE_IMAGE_IMPORT_API_KEY': 'private'})
        self.env.start()
        self.http = LiveServer(self.store)
        self.service = self.http.server.config.app.state.image_import
        self.service.transport = lambda *args: response()

    def tearDown(self):
        self.http.shutdown(); self.store.close(); self.directory.cleanup(); self.env.stop()

    def test_routes_auth_switch_errors_and_stats(self):
        self.assertFalse(self.req('GET', '/v1/import/image/config')['enabled'])
        self.req('GET', '/v1/admin/image-import', expect=403)
        self.req('POST', '/v1/admin/image-import', image_import.DEFAULTS, expect=403)
        self.req('POST', '/v1/import/image', picture(), expect=503)
        admin = {'X-Admin-Token': 'admin'}
        config = image_import.DEFAULTS | {'enabled': True, 'model': 'test'}
        self.req('POST', '/v1/admin/image-import', config, admin)
        self.assertTrue(self.req('GET', '/v1/import/image/config')['enabled'])
        self.req('POST', '/v1/import/image', picture(), expect=403)
        self.req('POST', '/v1/admin/image-import', config | {'requireAttest': False}, admin)
        self.req('POST', '/v1/import/image', {'imageBase64': 'bad'}, expect=400)
        device = FakeDevice()
        attest = AppAttest(self.store.db, self.store.lock, app_id=lambda: APP_ID, root=device.root_pem(), mode='enforce')
        attest.register(device.attestation(attest.challenge()['challenge']))
        self.http.server.config.app.state.attest = attest
        self.req('POST', '/v1/admin/image-import', config, admin)
        value = picture()
        signed = device.headers('POST', '/v1/import/image', json.dumps(value).encode(), int(time.time()))
        recognized = self.req('POST', '/v1/import/image', value, signed)
        self.assertEqual(recognized['courses'][0]['name'], '数学')
        self.req('POST', '/v1/import/image', value, signed, expect=401)
        stats = self.req('GET', '/v1/admin/image-import', headers=admin)
        self.assertNotIn('private', json.dumps(stats))
        self.assertEqual({row['outcome'] for row in stats['stats']['daily']}, {'attestRequired', 'invalidImage', 'success'})


if __name__ == '__main__': unittest.main()
