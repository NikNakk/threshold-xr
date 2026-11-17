import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('validator', Path(__file__).parents[1] / 'validate-ci.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class CIValidationTests(unittest.TestCase):
    def test_transient_status_failure_does_not_abort_successful_run(self):
        results = iter([subprocess.CalledProcessError(1, 'gh'),
                        {'status': 'in_progress', 'conclusion': ''},
                        {'status': 'completed', 'conclusion': 'success'}])
        def state():
            result = next(results)
            if isinstance(result, Exception):
                raise result
            return result
        sleeps = []
        validator.wait_for_ci(state, sleeps.append)
        self.assertEqual(sleeps, [10, 30])

    def test_failed_ci_run_is_not_reported_as_transient(self):
        with self.assertRaisesRegex(ValueError, 'failure'):
            validator.wait_for_ci(lambda: {'status': 'completed', 'conclusion': 'failure'},
                                  lambda _: self.fail('A failed run must not be polled again'))

    def test_repeated_status_errors_are_bounded(self):
        def state():
            raise json.JSONDecodeError('bad response', '', 0)
        sleeps = []
        with self.assertRaises(json.JSONDecodeError):
            validator.wait_for_ci(state, sleeps.append)
        self.assertEqual(sleeps, [10] * 4)
