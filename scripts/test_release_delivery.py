import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request

from release_delivery import DownloadRedirect, GitHub, MANIFEST, archive_name, download_release, publish, record, restore, verify


TAG = 'v0.2.0-beta.1'
COMMIT = 'a' * 40
SIGNATURE = base64.b64encode(bytes(64)).decode()


class FakeGitHub:
    """A durable server model; failures may happen after a mutation succeeds."""
    def __init__(self):
        self.tags = {}
        self.releases = {}
        self.files = {}
        self.starters = set()
        self.artifacts = {}
        self.mutations = []
        self.fail_after = None

    def tag_commit(self, tag):
        return self.tags.get(tag)

    def release(self, tag):
        return self.releases.get(tag)

    def artifact(self, run_id):
        return self.artifacts.get(run_id)

    def assets(self, release):
        return {name: {'name': name, 'id': name, 'state': 'starter' if name in self.starters else 'uploaded'} for name in self.files}

    def download(self, asset):
        return self.files[asset['id']]

    def changed(self, event):
        self.mutations.append(event)
        if self.fail_after == event:
            self.fail_after = None
            raise OSError('Connection lost after server accepted the request')

    def upload(self, release, path):
        if path.name in self.files:
            raise AssertionError('An existing asset must never be overwritten')
        self.files[path.name] = path.read_bytes()
        self.changed('upload:' + path.name)

    def request(self, path, method='GET', data=None):
        if path == 'git/refs' and method == 'POST':
            self.tags[data['ref'].removeprefix('refs/tags/')] = data['sha']
            self.changed('tag')
            return {}
        if path == 'releases' and method == 'POST':
            result = {**data, 'id': 1}
            self.releases[data['tag_name']] = result
            self.changed('draft')
            return result
        if path.startswith('releases/assets/') and method == 'DELETE':
            name = path.removeprefix('releases/assets/')
            del self.files[name]
            self.starters.discard(name)
            self.changed('delete:' + name)
            return None
        if path == 'releases/1' and method == 'PATCH':
            result = next(iter(self.releases.values()))
            result.update(data)
            self.changed('publish')
            return result
        raise AssertionError((method, path, data))


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / archive_name(TAG)
        self.archive.write_bytes(b'verified notarized archive')
        self.manifest = record(self.directory, TAG, COMMIT, SIGNATURE, self.archive.stat().st_size)
        self.server = FakeGitHub()

    def test_first_publication_targets_exact_commit_and_publishes_only_after_assets(self):
        publish(self.server, self.directory, TAG, COMMIT)
        self.assertEqual(self.server.tags[TAG], COMMIT)
        self.assertEqual(self.server.mutations, ['tag', 'draft', 'upload:release.json', 'upload:' + self.archive.name, 'publish'])
        self.assertFalse(self.server.release(TAG)['draft'])
        self.assertTrue(self.server.release(TAG)['prerelease'])
        self.assertEqual(self.server.release(TAG)['make_latest'], 'false')

    def test_every_partial_publication_can_resume_without_duplicate_or_replaced_assets(self):
        for event in ['tag', 'draft', 'upload:release.json', 'upload:' + self.archive.name, 'publish']:
            with self.subTest(event=event):
                server = FakeGitHub()
                server.fail_after = event
                with self.assertRaises(OSError):
                    publish(server, self.directory, TAG, COMMIT)
                publish(server, self.directory, TAG, COMMIT)
                self.assertFalse(server.release(TAG)['draft'])
                self.assertEqual(server.mutations.count('tag'), 1)
                self.assertEqual(server.mutations.count('draft'), 1)
                self.assertEqual(server.mutations.count('upload:release.json'), 1)
                self.assertEqual(server.mutations.count('upload:' + self.archive.name), 1)
                self.assertEqual(server.mutations.count('publish'), 1)

    def test_failed_upload_starter_can_be_replaced_only_in_a_draft(self):
        self.server.fail_after = 'draft'
        with self.assertRaises(OSError):
            publish(self.server, self.directory, TAG, COMMIT)
        self.server.files[MANIFEST] = b''
        self.server.starters.add(MANIFEST)
        publish(self.server, self.directory, TAG, COMMIT)
        self.assertIn('delete:release.json', self.server.mutations)
        self.assertFalse(self.server.release(TAG)['draft'])
        self.assertEqual(json.loads(self.server.files[MANIFEST]), self.manifest)

    def test_repeating_a_completed_publication_is_read_only(self):
        publish(self.server, self.directory, TAG, COMMIT)
        before = list(self.server.mutations)
        publish(self.server, self.directory, TAG, COMMIT)
        self.assertEqual(self.server.mutations, before)

    def test_conflicting_tag_or_legacy_version_is_rejected_before_mutations(self):
        for name, target in [(TAG, 'b' * 40), (TAG.removeprefix('v'), COMMIT)]:
            server = FakeGitHub()
            server.tags[name] = target
            with self.assertRaises(ValueError):
                publish(server, self.directory, TAG, COMMIT)
            self.assertEqual(server.mutations, [])

    def test_existing_draft_or_published_asset_is_never_replaced(self):
        for draft in [True, False]:
            server = FakeGitHub()
            publish(server, self.directory, TAG, COMMIT)
            server.release(TAG)['draft'] = draft
            server.files[self.archive.name] = b'different published bytes'
            before = list(server.mutations)
            with self.assertRaisesRegex(ValueError, 'differs'):
                publish(server, self.directory, TAG, COMMIT)
            self.assertEqual(server.mutations, before)

    def test_published_release_with_missing_asset_is_not_repaired_by_mutation(self):
        publish(self.server, self.directory, TAG, COMMIT)
        del self.server.files[MANIFEST]
        before = list(self.server.mutations)
        with self.assertRaisesRegex(ValueError, 'never modified'):
            publish(self.server, self.directory, TAG, COMMIT)
        self.assertEqual(self.server.mutations, before)

    def test_checksum_and_source_identity_are_verified_before_any_mutation(self):
        with self.assertRaisesRegex(ValueError, 'commit mismatch'):
            publish(self.server, self.directory, TAG, 'b' * 40)
        self.archive.write_bytes(b'tampered notarized archive')
        with self.assertRaisesRegex(ValueError, 'checksum or length'):
            publish(self.server, self.directory, TAG, COMMIT)
        self.assertEqual(self.server.mutations, [])

    def test_manifest_cannot_redirect_verification_outside_artifact(self):
        self.manifest['archive'] = '../other.zip'
        (self.directory / MANIFEST).write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'archive mismatch'):
            verify(self.directory, TAG, COMMIT)

    def test_rerun_reuses_this_runs_artifact_even_after_partial_release_upload(self):
        self.server.fail_after = 'draft'
        with self.assertRaises(OSError):
            publish(self.server, self.directory, TAG, COMMIT)
        self.server.artifacts['123'] = {'id': 1234}
        self.assertEqual(restore(self.server, self.directory, TAG, COMMIT, '123'), {'artifact_exists': 'true', 'restored': 'true'})

    def test_new_run_reuses_published_archive(self):
        publish(self.server, self.directory, TAG, COMMIT)
        destination = self.directory / 'restored'
        self.assertEqual(restore(self.server, destination, TAG, COMMIT, '456'), {'artifact_exists': 'false', 'restored': 'true'})
        self.assertEqual((destination / self.archive.name).read_bytes(), self.archive.read_bytes())
        self.assertEqual(verify(destination, TAG, COMMIT), self.manifest)

    def test_incomplete_draft_without_saved_artifact_is_not_rebuilt(self):
        self.server.fail_after = 'draft'
        with self.assertRaises(OSError):
            publish(self.server, self.directory, TAG, COMMIT)
        with self.assertRaisesRegex(ValueError, 'rerun the original workflow'):
            restore(self.server, self.directory, TAG, COMMIT, '456')

    def test_feed_cannot_advertise_a_draft(self):
        publish(self.server, self.directory, TAG, COMMIT)
        self.server.release(TAG)['draft'] = True
        with self.assertRaisesRegex(ValueError, 'still a draft'):
            download_release(self.server, self.server.release(TAG), self.directory / 'feed', TAG, COMMIT, published_only=True)

    def test_stable_release_is_marked_latest(self):
        tag = 'v0.2.0'
        archive = self.directory / archive_name(tag)
        archive.write_bytes(self.archive.read_bytes())
        record(self.directory, tag, COMMIT, SIGNATURE, archive.stat().st_size)
        publish(self.server, self.directory, tag, COMMIT)
        self.assertEqual(self.server.release(tag)['make_latest'], 'true')
        self.assertFalse(self.server.release(tag)['prerelease'])


class TransportTests(unittest.TestCase):
    def test_only_not_found_can_be_treated_as_absence(self):
        with patch.dict('os.environ', {'GH_TOKEN': 'test-token'}):
            client = GitHub()
        for status in [401, 403, 429, 500]:
            with patch.object(client.opener, 'open', side_effect=HTTPError('https://api.github.com/', status, 'failure', {}, None)):
                with self.assertRaisesRegex(ValueError, str(status)):
                    client.release(TAG)
        with patch.object(client.opener, 'open', side_effect=HTTPError('https://api.github.com/', 404, 'missing', {}, None)):
            self.assertIsNone(client.release(TAG))

    def test_cross_host_download_redirect_drops_credentials(self):
        request = Request('https://api.github.com/repos/example', headers={'Authorization': 'Bearer test'})
        redirected = DownloadRedirect().redirect_request(request, None, 302, 'Found', {}, 'https://release-assets.githubusercontent.com/archive')
        self.assertIsNone(redirected.get_header('Authorization'))

    def test_annotated_tag_resolves_to_its_commit(self):
        with patch.dict('os.environ', {'GH_TOKEN': 'test-token'}):
            client = GitHub()
        with patch.object(client, 'request', side_effect=[{'object': {'type': 'tag', 'sha': 'b' * 40}}, {'object': {'type': 'commit', 'sha': COMMIT}}]):
            self.assertEqual(client.tag_commit(TAG), COMMIT)


if __name__ == '__main__':
    unittest.main()
