import base64
import io
import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.error
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
                              startPeriod=1, endPeriod=2, weeks=[1, 3, 5])], warnings=[]) | fields


def response(value=None, status='completed'):
    return dict(status=status, output=[{'type': 'message', 'content': [
        {'type': 'output_text', 'text': json.dumps(value or result())}]}],
        usage={'input_tokens': 100, 'output_tokens': 50})


class RecognitionTests(unittest.TestCase):
    def setUp(self):
        logging = patch.object(image_import.LOGGER, 'error')
        self.logged_errors = logging.start(); self.addCleanup(logging.stop)
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
        return str(found.exception)

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

    def test_reasoning_effort_persistence_legacy_config_and_validation(self):
        legacy = {key: value for key, value in self.config.items() if key != 'reasoningEffort'}
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE image_import_config SET value=?', (json.dumps(legacy),))
        self.assertEqual(self.service.config()['reasoningEffort'], '')
        for effort in ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', ''):
            with self.subTest(effort=effort):
                saved = self.service.save_config(self.config | {'reasoningEffort': effort})
                self.assertEqual(saved['reasoningEffort'], effort)
                restarted = image_import.ImageImport(self.store.db, self.store.lock)
                self.assertEqual(restarted.config()['reasoningEffort'], effort)
                self.assertEqual(self.service.save_config(legacy)['reasoningEffort'], effort)
        self.service.save_config(self.config | {'reasoningEffort': 'low'})
        for invalid in (None, True, 1, [], {}, 'turbo'):
            with self.assertRaises(ValueError):
                self.service.save_config(self.config | {'reasoningEffort': invalid})
            self.assertEqual(self.service.config()['reasoningEffort'], 'low')
        self.recognize()
        self.assertEqual(self.calls[-1][0]['reasoningEffort'], 'low')
        self.assertNotIn('reasoningEffort', self.service.public())

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

    def test_prompt_defaults_custom_persistence_legacy_save_and_reset(self):
        default = self.service.admin_config()
        self.assertEqual(default['prompt'], '')
        self.assertEqual(default['defaultPrompt'], image_import.DEFAULT_PROMPT)
        self.assertEqual(default['promptMaxLength'], image_import.MAX_PROMPT_LENGTH)
        custom = '先读星期表头。\n再读取每节课和时间。'
        saved = self.service.save_config(self.config | {'prompt': '  ' + custom + '\n'})
        self.assertEqual(saved['prompt'], custom)
        restarted = image_import.ImageImport(self.store.db, self.store.lock)
        self.assertEqual(restarted.config()['prompt'], custom)
        # An old admin tab must not silently erase a newer prompt override.
        for omitted in ({'prompt'}, {'prompt', 'apiKey'}):
            legacy = {key: value for key, value in self.config.items() if key not in omitted}
            self.assertEqual(self.service.save_config(legacy)['prompt'], custom)
        self.recognize()
        self.assertEqual(self.calls[-1][0]['prompt'], custom)
        self.assertNotIn('prompt', self.service.public())
        self.assertNotIn('defaultPrompt', self.service.public())
        for reset in ('', ' \n\t', image_import.DEFAULT_PROMPT):
            self.service.save_config(self.config | {'prompt': custom})
            self.assertEqual(self.service.save_config(self.config | {'prompt': reset})['prompt'], '')
        with patch.object(image_import, 'DEFAULT_PROMPT', '新版默认提示词'):
            self.assertEqual(self.service.admin_config()['defaultPrompt'], '新版默认提示词')
            self.assertEqual(self.service.config()['prompt'], '')

    def test_old_stored_configuration_uses_default_prompt(self):
        legacy = {key: value for key, value in self.config.items() if key != 'prompt'}
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE image_import_config SET value=? WHERE id=1', (json.dumps(legacy),))
        self.assertEqual(self.service.config()['prompt'], '')
        self.assertEqual(self.service.admin_config()['defaultPrompt'], image_import.DEFAULT_PROMPT)

    def test_invalid_prompt_does_not_replace_saved_configuration(self):
        self.service.save_config(self.config | {'prompt': '已保存的提示词'})
        for invalid in (None, 1, [], '字' * (image_import.MAX_PROMPT_LENGTH + 1)):
            with self.subTest(value_type=type(invalid)), self.assertRaisesRegex(ValueError, '识别提示词'):
                self.service.save_config(self.config | {'prompt': invalid})
            self.assertEqual(self.service.config()['prompt'], '已保存的提示词')

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
        for field, bad in [('weekday', True), ('startPeriod', 0), ('endPeriod', 21), ('weeks', [41]), ('name', ['invalid'])]:
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

    def test_partial_period_settings_keep_actual_indices_and_missing_endpoints(self):
        value = result(periodCount=8, periodTimes=[
            {'period': 6, 'start': '14:55', 'end': None},
            {'period': 5, 'start': '14:00', 'end': '14:45'},
        ])
        value['courses'][0].update(startPeriod=5, endPeriod=6)
        self.service.transport = lambda *args: response(value)
        recognized = self.recognize()
        self.assertEqual(recognized['periodCount'], 8)
        self.assertEqual(recognized['classTimes'], [])
        self.assertEqual([item['period'] for item in recognized['periodTimes']], [5, 6])
        self.assertIsNone(recognized['periodTimes'][1]['end'])
        self.assertEqual(recognized['courses'][0]['startPeriod'], 5)

    def test_complete_partial_times_are_safe_for_old_clients(self):
        value = result(periodCount=2, periodTimes=[
            {'period': 2, 'start': '08:55', 'end': '09:40'},
            {'period': 1, 'start': '08:00', 'end': '08:45'},
        ])
        recognized = image_import.validate_result(value)
        self.assertEqual(recognized['classTimes'], [
            {'start': '08:00', 'end': '08:45'}, {'start': '08:55', 'end': '09:40'}])
        self.assertEqual(recognized['periodTimes'], [])

    def test_short_time_table_does_not_discard_later_courses(self):
        value = result(classTimes=[{'start': '08:00', 'end': '08:45'}])
        recognized = image_import.validate_result(value)
        self.assertEqual(recognized['classTimes'], [])
        self.assertEqual(recognized['periodTimes'], [{'period': 1, 'start': '08:00', 'end': '08:45'}])
        self.assertEqual(recognized['courses'][0]['endPeriod'], 2)

    def test_period_count_without_times_is_preserved(self):
        recognized = image_import.validate_result(result(periodCount=12, periodTimes=[]))
        self.assertEqual(recognized['periodCount'], 12)
        self.assertEqual(recognized['classTimes'], [])

    def test_partial_prefix_does_not_invent_a_daily_period_count(self):
        times = [{'period': 1, 'start': '08:00', 'end': '08:45'},
                 {'period': 2, 'start': '08:55', 'end': '09:40'}]
        recognized = image_import.validate_result(result(periodTimes=times))
        self.assertIsNone(recognized['periodCount'])
        self.assertEqual(recognized['periodTimes'], times)
        self.assertEqual(recognized['classTimes'], [])

    def test_invalid_partial_settings_report_specific_fields(self):
        period = {'period': 5, 'start': '14:00', 'end': '14:45'}
        cases = [
            ({'periodCount': True}, '每天总节数'),
            ({'periodCount': 21}, '每天总节数'),
            ({'periodCount': 1}, '结束节次'),
            ({'periodTimes': [period, period]}, '第 5 节重复'),
            ({'periodTimes': [period | {'period': 0}]}, '节次编号'),
            ({'periodTimes': [period | {'start': '8点'}]}, '第 5 节的时间格式'),
            ({'periodTimes': [period | {'end': '13:00'}]}, '第 5 节的时间倒置'),
            ({'periodTimes': [period, {'period': 6, 'start': '14:30', 'end': None}]}, '第 6 节'),
            ({'periodCount': 4, 'periodTimes': [period]}, '节次编号'),
            ({'semesterStartMonday': '2026-99-99'}, '学期日期'),
        ]
        for fields, expected in cases:
            with self.subTest(fields=fields), self.assertRaisesRegex(image_import.ImportError, expected):
                image_import.response_result(response(result(**fields)))

    def test_upstream_errors_are_actionable_without_exposing_private_details(self):
        self.service.save_config(self.config | {'deviceDailyLimit': 100})
        cases = [(TimeoutError('private upstream detail'), '60 秒'),
                 (urllib.error.URLError(TimeoutError('private upstream detail')), '超时'),
                 (urllib.error.URLError('private upstream detail'), '无法连接')]
        for status, expected in [(400, '结构化输出'), (401, '密钥'), (403, '权限'), (404, '模型'),
                                 (413, '大小限制'), (422, '兼容性'), (429, '额度'), (503, '暂时不可用')]:
            cases.append((urllib.error.HTTPError('https://private', status, 'private upstream detail', {},
                                                io.BytesIO(b'private upstream detail')), expected))
        for exception, expected in cases:
            def fail(*args): raise exception
            self.service.transport = fail
            message = self.error(502, self.recognize)
            self.assertIn(expected, message)
            self.assertNotIn('private', message)
            if isinstance(exception, urllib.error.HTTPError): self.assertIn(f'HTTP {exception.code}', message)
        self.assertEqual(self.service.stats()['daily'][0]['outcome'], 'upstreamError')
        self.assertEqual(self.service.stats()['daily'][0]['requests'], len(cases))

    def test_incomplete_refusal_empty_and_invalid_json_have_distinct_errors(self):
        self.service.save_config(self.config | {'deviceDailyLimit': 100})
        cases = [
            (response(status='incomplete') | {'incomplete_details': {'reason': 'max_output_tokens'}}, '长度上限'),
            (response(status='incomplete') | {'incomplete_details': {'reason': 'content_filter'}}, '内容过滤'),
            (response(status='incomplete'), '未完成输出'),
            (response(status='failed') | {'error': {'message': 'private upstream detail'}}, '处理请求失败'),
            (response(status='queued'), '同步返回'),
            ({'output': [{'type': 'message', 'content': [{'type': 'refusal', 'refusal': 'private'}]}]}, '拒绝处理'),
            ({'status': 'completed', 'output': [], 'usage': []}, '缺少 output_text'),
            ({'output_text': 'private invalid JSON'}, '不是有效 JSON'),
            ({'output_text': '[]'}, '识别结果校验失败'),
            ([], 'Responses JSON 对象'),
        ]
        for upstream, expected in cases:
            self.service.transport = lambda *args: upstream
            message = self.error(502, self.recognize)
            self.assertIn(expected, message)
            self.assertNotIn('private', message)
        rows = self.service.stats()['daily']
        self.assertEqual(sum(row['inputTokens'] for row in rows), 500)
        self.assertEqual(sum(row['requests'] for row in rows), len(cases))

    def test_upstream_json_error_preserves_parameter_and_redacts_request_data(self):
        response_body = None
        def fail(config, image, api_key):
            nonlocal response_body
            response_body = io.BytesIO(json.dumps({'error': {
                'message': f'Unsupported parameter text.format.strict. key={api_key}; Bearer other-secret; '
                           f'data:image/jpeg;base64,{image}; https://example.com/?token=secret; sk-another-key',
                'param': 'text.format.strict', 'code': 'unsupported_parameter',
                'request': {'imageBase64': image, 'apiKey': api_key},
            }}).encode())
            raise urllib.error.HTTPError(config['endpoint'], 400, 'Bad Request', {}, response_body)
        self.service.transport = fail
        message = self.error(502, self.recognize)
        self.assertIn('上游详情：Unsupported parameter', message)
        self.assertIn('参数：text.format.strict', message)
        self.assertIn('代码：unsupported_parameter', message)
        self.assertIn('[已隐藏]', message)
        for secret in ('test-server-key', 'other-secret', 'sk-another-key', 'token=secret', 'imageBase64'):
            self.assertNotIn(secret, message)
        self.assertTrue(response_body.closed)
        self.assertEqual(self.service.stats()['daily'][0]['outcome'], 'upstreamError')
        with self.store.lock:
            stored = dict(self.store.db.execute('SELECT * FROM image_import_events').fetchone())
        self.assertIn('Unsupported parameter', stored['error_message'])
        self.assertEqual((stored['error_status'], stored['upstream_status']), (502, 400))
        self.assertIn(f"错误记录：#{stored['id']}", message)
        recent = self.service.stats()['recentErrors'][0]
        self.assertEqual(recent['message'], stored['error_message'])
        self.assertEqual(recent['id'], stored['id'])
        self.assertEqual(recent['upstreamStatus'], 400)
        logged = self.logged_errors.call_args.args
        log_line = logged[0] % logged[1:]
        self.assertIn(f"event={stored['id']}", log_line)
        self.assertIn('Unsupported parameter', log_line)
        self.assertIn('upstream_status=400', log_line)
        for secret in ('test-server-key', 'other-secret', 'sk-another-key', 'token=secret', 'imageBase64'):
            self.assertNotIn(secret, json.dumps(stored))
            self.assertNotIn(secret, log_line)

    def test_existing_event_table_is_migrated_without_losing_history(self):
        db = sqlite3.connect(':memory:')
        db.row_factory = sqlite3.Row
        self.addCleanup(db.close)
        db.execute('''CREATE TABLE image_import_events (
            id INTEGER PRIMARY KEY, created REAL NOT NULL, day TEXT NOT NULL,
            device TEXT NOT NULL, address TEXT NOT NULL, outcome TEXT NOT NULL,
            model TEXT NOT NULL DEFAULT '', input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0, course_count INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0)''')
        db.execute('INSERT INTO image_import_events(created,day,device,address,outcome) VALUES (?,?,?,?,?)',
                   (self.stamp, image_import.day(self.stamp), 'hashed-device', 'hashed-ip', 'success'))
        lock = threading.RLock()
        for _ in range(2):
            service = image_import.ImageImport(db, lock, clock=lambda: self.stamp)
            row = db.execute('SELECT * FROM image_import_events').fetchone()
            self.assertEqual(row['outcome'], 'success')
            self.assertEqual(row['error_message'], '')
            self.assertEqual(row['error_status'], 0)
            self.assertEqual(service.stats()['recentErrors'], [])

    def test_error_history_is_bounded_persistent_and_expires(self):
        for index in range(55):
            event = self.service.record('invalidResult', 'device', 'address', self.config)
            self.service.report_error(event, image_import.ImportError(502, f'测试错误 {index}'), self.config)
        restarted = image_import.ImageImport(self.store.db, self.store.lock, clock=lambda: self.stamp)
        errors = restarted.stats()['recentErrors']
        self.assertEqual(len(errors), 50)
        self.assertEqual([entry['id'] for entry in errors], list(range(55, 5, -1)))
        self.assertEqual(errors[0]['message'], '测试错误 54')
        self.assertFalse({'device', 'address'} & set(errors[0]))
        self.stamp += 31 * 86400
        self.assertEqual(restarted.stats()['recentErrors'], [])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM image_import_events').fetchone()[0], 55)
        self.stamp += 60 * 86400
        self.assertEqual(restarted.stats()['recentErrors'], [])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM image_import_events').fetchone()[0], 0)

    def test_local_failures_are_also_visible_to_admin(self):
        self.error(400, lambda: self.recognize(value={'imageBase64': 'invalid'}))
        self.service.transport = lambda *args: {'output_text': '[]'}
        self.error(502, self.recognize)
        errors = self.service.stats()['recentErrors']
        self.assertEqual([entry['outcome'] for entry in errors], ['invalidResult', 'invalidImage'])
        self.assertIn('校验失败', errors[0]['message'])
        self.assertEqual([entry['status'] for entry in errors], [502, 400])
        self.assertEqual(self.logged_errors.call_count, 2)

    def test_invalid_or_oversized_upstream_error_body_keeps_http_reason(self):
        for raw in (b'<html>private debug page</html>', b'{}', b'[]',
                    json.dumps({'error': {'message': 'private' * 4000}}).encode()):
            error = urllib.error.HTTPError('https://example.com', 400, 'private', {}, io.BytesIO(raw))
            detail = image_import.upstream_error_detail(error, 'key', 'image')
            self.assertEqual(detail, '')
            self.assertIn('HTTP 400', image_import.upstream_http_message(400, detail))

    def test_compatible_text_and_fenced_json_are_validated(self):
        value = result()
        upstream = {'output_text': '```json\n' + json.dumps(value) + '\n```'}
        self.assertEqual(image_import.response_result(upstream)['courses'], value['courses'])
        self.assertEqual(image_import.response_result(response(value) | {'status': None})['courses'], value['courses'])
        # A complete-looking text field must not override the incomplete status.
        with self.assertRaisesRegex(image_import.ImportError, '未完成输出'):
            image_import.response_result(upstream | {'status': 'incomplete'})

    def test_all_recognition_fields_can_be_missing_or_null(self):
        for value in ({}, {key: None for key in image_import.RESULT_SCHEMA['properties']}):
            recognized = image_import.response_result({'output_text': json.dumps(value)})
            self.assertNotIn('name', recognized)
            self.assertEqual(recognized['courses'], [])
            self.assertEqual(recognized['classTimes'], [])
            self.assertIsNone(recognized['semesterStartMonday'])
        value = result(courses=[{'name': '数学'}, {'name': None, 'teacher': '李老师', 'endPeriod': 6},
                                {'weekday': None, 'startPeriod': 12, 'weeks': None}])
        recognized = image_import.validate_result(value)
        self.assertEqual(len(recognized['courses']), 3)
        self.assertIsNone(recognized['courses'][0]['weekday'])
        self.assertEqual(recognized['courses'][0]['weeks'], [])
        self.assertEqual(recognized['courses'][1]['teacher'], '李老师')
        self.assertEqual(recognized['courses'][1]['name'], '')
        self.assertEqual(recognized['courses'][2]['startPeriod'], 12)

    def test_partial_time_fields_and_unknown_period_number_keep_readable_data(self):
        value = result(classTimes=[{'start': '08:00', 'end': None}], periodTimes=[
            {'period': 5, 'start': None, 'end': None},
            {'period': None, 'start': '14:00', 'end': '14:45'},
        ], courses=[])
        recognized = image_import.validate_result(value)
        self.assertEqual(recognized['periodTimes'], [{'period': 1, 'start': '08:00', 'end': None}])
        self.assertEqual(recognized['classTimes'], [])
        self.assertIn('14:00', recognized['warnings'][0])
        self.assertIn('14:45', recognized['warnings'][0])

    def test_partial_course_response_reaches_the_client(self):
        self.service.transport = lambda *args: response({'courses': [{'classroom': 'A101'}]})
        recognized = self.recognize()
        self.assertEqual(recognized['courses'][0]['classroom'], 'A101')
        self.assertIsNone(recognized['courses'][0]['weekday'])
        self.assertEqual(self.service.stats()['daily'][0]['courses'], 1)

    def test_timetable_title_is_not_requested_and_legacy_titles_are_ignored(self):
        self.assertNotIn('name', image_import.RESULT_SCHEMA['properties'])
        self.assertNotIn('name', image_import.RESULT_SCHEMA['required'])
        value = image_import.validate_result(result(name='某同学的个人课表'))
        self.assertNotIn('name', value)
        self.assertEqual(value['courses'][0]['name'], '数学')

    def test_compact_result_expands_for_app_and_stats(self):
        compact = dict(s=None, w=20, p=2, t=[dict(s='08:00', e='08:45'),
                      dict(s='08:55', e='09:40')], pt=[],
                      c=[dict(n='数学', t='老师', r='A101', d=1, s=1, e=2, w='1-4,3-9/2,18')])
        expected = result(weekCount=20, periodCount=2,
                          classTimes=[dict(start='08:00', end='08:45'), dict(start='08:55', end='09:40')],
                          courses=[dict(name='数学', teacher='老师', classroom='A101', weekday=1,
                                        startPeriod=1, endPeriod=2, weeks=[1, 2, 3, 4, 5, 7, 9, 18])])
        self.service.transport = lambda *args: response(compact)
        recognized = self.recognize()
        self.assertEqual(recognized, image_import.validate_result(expected))
        self.assertEqual(self.service.stats()['daily'][0]['courses'], 1)
        self.assertNotIn('c', recognized)
        self.assertEqual(recognized['warnings'], [])

    def test_grouped_courses_preserve_each_arrangement_and_unknowns(self):
        value = dict(c=[dict(n='数学', t='张老师', a=[
            dict(r='A101', d=1, s=1, e=2, w='1-16'),
            dict(r='B202', d=3, s=3, e=4, w='2-16/2')]),
            dict(n='数学', t='李老师', a=[dict(r=None, d=5, s=1, e=2, w='')]),
            dict(n='只读到课名', t=None, a=[])])
        self.service.transport = lambda *args: response(value)
        courses = self.recognize()['courses']
        self.assertEqual(len(courses), 4)
        self.assertEqual([c['teacher'] for c in courses], ['张老师', '张老师', '李老师', ''])
        self.assertEqual([c['classroom'] for c in courses], ['A101', 'B202', '', ''])
        self.assertEqual([c['weekday'] for c in courses], [1, 3, 5, None])
        self.assertEqual(courses[0]['weeks'], list(range(1, 17)))
        self.assertEqual(courses[1]['weeks'], list(range(2, 17, 2)))
        self.assertEqual(courses[2]['weeks'], [])
        self.assertEqual(courses[3]['name'], '只读到课名')
        self.assertEqual(self.service.stats()['daily'][0]['courses'], 4)

    def test_grouped_courses_reject_invalid_and_oversized_arrangements(self):
        for groups in ([dict(n='数学', a=None)], [dict(a={})], [dict(a=[None])],
                       [dict(a=[], w='1-16')], [dict(a=[dict(n='其他课')])],
                       [dict(a=[dict(w='1-41')])], [dict(a=[{}] * 201)],
                       [dict(a=[{}] * 101), dict(a=[{}] * 100)]):
            with self.subTest(groups=groups), self.assertRaises(image_import.ImportError):
                image_import.response_result(response(dict(c=groups)))

    def test_compact_partial_and_unknown_fields_stay_unknown(self):
        compact = dict(s=None, w=None, p=8, t=[], pt=[dict(p=5, s='14:00', e=None)],
                      c=[dict(n='数学', t=None, r=None, d=None, s=None, e=None, w='')])
        recognized = image_import.response_result(response(compact))
        self.assertEqual(recognized['periodTimes'], [dict(period=5, start='14:00', end=None)])
        self.assertEqual(recognized['classTimes'], [])
        self.assertEqual(recognized['courses'][0]['weeks'], [])
        self.assertIsNone(recognized['courses'][0]['weekday'])
        self.assertEqual(recognized['courses'][0]['teacher'], '')

    def test_compact_ranges_and_invalid_results(self):
        for expression, expected in [('', []), ('1-16', list(range(1, 17))),
                                     ('2-16/2', list(range(2, 17, 2))), ('40,1,1-3', [1, 2, 3, 40])]:
            self.assertEqual(image_import.expand_week_ranges(expression), expected)
        for invalid in ('0', '41', '5-2', '1-99', '1-8/0', '1-8/3', '1/2', '1,,2', '全学期',
                        '1-4周', None, [], 3, '1' * 201):
            with self.subTest(invalid=invalid), self.assertRaises(image_import.ImportError):
                image_import.response_result(response({'c': [dict(n='数学', w=invalid)]}))
        for invalid in ({'c': {}}, {'c': ''}, {'c': [None]}, {'c': [{'unknown': 1}]},
                        {'c': [], 'courses': []}, {'pt': [dict(p=21)]}, {'c': [{}] * 201},
                        {'w': 2, 'c': [dict(w='1-3')]}, {'c': [dict(d=8, w='1')]}):
            with self.subTest(invalid=invalid), self.assertRaises(image_import.ImportError):
                image_import.response_result(response(invalid))

    def test_responses_wire_format_is_image_and_strict_schema_without_tools(self):
        class Reply:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return json.dumps(response()).encode()
        class Opener:
            def open(self, request, timeout):
                # This gateway accepts arrays but rejects complex union members,
                # matching the reported unknown variant "array" failure.
                def check_schema(schema):
                    if isinstance(schema, dict):
                        if isinstance(schema.get('type'), list):
                            if 'array' in schema['type']: raise ValueError('unknown variant "array"')
                        for value in schema.values(): check_schema(value)
                    elif isinstance(schema, list):
                        for value in schema: check_schema(value)
                check_schema(json.loads(request.data)['text']['format']['schema'])
                self.request, self.timeout = request, timeout
                return Reply()
        opener = Opener()
        encoded = image_import.normalize_image(picture())
        with patch('urllib.request.build_opener', return_value=opener):
            for prompt, expected in [('', image_import.DEFAULT_PROMPT), (' \n ', image_import.DEFAULT_PROMPT),
                                     ('自定义提示词\n保留课程与节次', '自定义提示词\n保留课程与节次')]:
                image_import.responses(self.config | {'prompt': prompt}, encoded, 'key')
                payload = json.loads(opener.request.data)
                self.assertEqual(payload['instructions'], expected + '\n' + image_import.WIRE_INSTRUCTIONS)
                self.assertEqual(payload['text']['format']['schema'], image_import.WIRE_SCHEMA)
                self.assertNotIn('reasoning', payload)
            for effort in ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', ''):
                image_import.responses(self.config | {'reasoningEffort': effort}, encoded, 'key')
                payload = json.loads(opener.request.data)
                if effort:
                    self.assertEqual(payload['reasoning'], {'effort': effort})
                else:
                    self.assertNotIn('reasoning', payload)
        payload = json.loads(opener.request.data)
        self.assertFalse(payload['store'])
        self.assertEqual(payload['text']['format']['type'], 'json_schema')
        self.assertTrue(payload['text']['format']['strict'])
        image_part = payload['input'][0]['content'][1]
        self.assertEqual(image_part['image_url'], 'data:image/jpeg;base64,' + encoded)
        self.assertEqual(image_part['type'], 'input_image')
        self.assertEqual(image_part['detail'], 'high')
        self.assertEqual(payload['input'][0]['role'], 'user')
        with Image.open(io.BytesIO(base64.b64decode(image_part['image_url'].split(',', 1)[1]))) as decoded:
            self.assertEqual(decoded.format, 'JPEG')
            self.assertEqual(decoded.size, (120, 80))
        self.assertNotIn('tools', payload)
        schema = payload['text']['format']['schema']
        self.assertIn('p', schema['required'])
        self.assertIn('pt', schema['required'])
        for name in ('t', 'pt', 'c'):
            self.assertEqual(schema['properties'][name]['type'], 'array')
        self.assertNotIn('warnings', schema['properties'])
        self.assertEqual(schema['properties']['c']['items']['properties']['a']['items']['properties']['w']['type'], 'string')
        self.assertEqual(opener.request.get_header('Authorization'), 'Bearer key')


class ImageImportHTTPTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        logging = patch.object(image_import.LOGGER, 'error')
        self.logged_errors = logging.start(); self.addCleanup(logging.stop)
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

    def test_route_preserves_failure_reason(self):
        self.service.save_config(image_import.DEFAULTS | {'enabled': True, 'model': 'test', 'requireAttest': False})
        self.service.transport = lambda *args: response(status='incomplete') | {'incomplete_details': {'reason': 'max_output_tokens'}}
        error = self.req('POST', '/v1/import/image', picture(), expect=502)
        self.assertIn('长度上限', error['error'])
        self.assertIn('最大输出 token', error['error'])

    def test_route_exposes_upstream_bad_request_details(self):
        self.service.save_config(image_import.DEFAULTS | {'enabled': True, 'model': 'test', 'requireAttest': False})
        def fail(*args):
            body = json.dumps({'error': {'message': 'unknown variant "array"', 'param': 'text.format.schema', 'code': 'invalid_request_error'}}).encode()
            raise urllib.error.HTTPError('https://example.com/responses', 400, 'Bad Request', {}, io.BytesIO(body))
        self.service.transport = fail
        error = self.req('POST', '/v1/import/image', picture(), expect=502)
        self.assertIn('HTTP 400', error['error'])
        self.assertIn('unknown variant "array"', error['error'])
        self.assertIn('text.format.schema', error['error'])
        self.assertIsInstance(error['errorID'], int)
        self.req('GET', '/v1/admin/image-import', expect=403)
        admin = self.req('GET', '/v1/admin/image-import', headers={'X-Admin-Token': 'admin'})
        latest = admin['stats']['recentErrors'][0]
        self.assertEqual(latest['id'], error['errorID'])
        self.assertEqual((latest['status'], latest['upstreamStatus']), (502, 400))
        self.assertIn('unknown variant "array"', latest['message'])
        self.assertNotIn('recentErrors', self.req('GET', '/v1/import/image/config'))

    def test_admin_prompt_edit_reset_auth_and_next_recognition(self):
        admin = {'X-Admin-Token': 'admin'}
        config = image_import.DEFAULTS | {'enabled': True, 'model': 'test', 'requireAttest': False, 'prompt': '自定义读取规则\n保留教师和节次'}
        self.req('POST', '/v1/admin/image-import', config, expect=403)
        saved = self.req('POST', '/v1/admin/image-import', config, admin)['config']
        self.assertEqual(saved['prompt'], config['prompt'])
        self.assertEqual(saved['defaultPrompt'], image_import.DEFAULT_PROMPT)
        loaded = self.req('GET', '/v1/admin/image-import', headers=admin)['config']
        self.assertEqual(loaded['prompt'], config['prompt'])
        self.assertEqual(set(self.req('GET', '/v1/import/image/config')), {'enabled', 'maxImageBytes'})
        prompts = []
        def recognize(config, *args):
            prompts.append(config['prompt'])
            return response()
        self.service.transport = recognize
        self.req('POST', '/v1/import/image', picture())
        reset = self.req('POST', '/v1/admin/image-import', config | {'prompt': ''}, admin)['config']
        self.assertEqual(reset['prompt'], '')
        self.req('POST', '/v1/import/image', picture())
        self.assertEqual(prompts, [config['prompt'], ''])
        audit = self.req('GET', '/v1/admin/audit', headers=admin)['entries']
        prompt_saves = [entry for entry in audit if entry['action'] == 'imageImport.save']
        self.assertEqual([entry['detail']['customPrompt'] for entry in prompt_saves], [False, True])
        self.assertNotIn(config['prompt'], json.dumps(audit, ensure_ascii=False))


if __name__ == '__main__': unittest.main()
