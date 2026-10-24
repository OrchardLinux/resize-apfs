import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_plan', ROOT / 'scripts/release-plan.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleasePlanTests(unittest.TestCase):
    def test_private_manual_build_retains_assets_without_attestation(self):
        p = module.plan('workflow_dispatch', 'preview', 'true', 'refs/heads/main', '123')
        self.assertEqual(p['release_tag'], 'private-preview-123')
        self.assertEqual(p['release_kind'], 'private-preview')
        self.assertEqual(p['attest'], 'false')

    def test_public_tagged_build_is_attested(self):
        p = module.plan('push', 'v0.1.0', 'false', 'refs/tags/v0.1.0', '124')
        self.assertEqual(p['release_tag'], 'v0.1.0')
        self.assertEqual(p['release_kind'], 'release')
        self.assertEqual(p['attest'], 'true')

    def test_private_tag_does_not_attest(self):
        p = module.plan('push', 'v0.1.0', 'true', 'refs/tags/v0.1.0', '124')
        self.assertEqual(p['attest'], 'false')
        self.assertEqual(p['release_kind'], 'private-preview')

    def test_public_manual_build_only_uploads_workflow_artifacts(self):
        p = module.plan('workflow_dispatch', 'preview', 'false', 'refs/heads/main', '125')
        self.assertEqual(p['release_tag'], '')
        self.assertEqual(p['attest'], 'true')

    def test_manual_run_on_tag_is_not_a_tag_push(self):
        p = module.plan('workflow_dispatch', 'preview', 'true', 'refs/tags/v0.1.0', '126')
        self.assertEqual(p['release_tag'], 'private-preview-126')

    def test_invalid_inputs_fail_before_building(self):
        for args in [
            ('push', 'preview', 'true', 'refs/heads/main', '123'),
            ('pull_request', 'preview', 'true', 'refs/heads/main', '123'),
            ('workflow_dispatch', '../../bad', 'true', 'refs/heads/main', '123'),
            ('workflow_dispatch', 'preview', '', 'refs/heads/main', '123'),
            ('workflow_dispatch', 'preview', 'true', 'refs/heads/main', ''),
        ]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                module.plan(*args)
