import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from release import FEED_URL, release_metadata, sparkle, update_appcast, validate_appcast, validate_source, verify_bundle


SIGNATURE = base64.b64encode(bytes(64)).decode()
EMPTY_FEED = '<rss version="2.0"><channel><title>GameMode</title><language>en</language></channel></rss>'


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "appcast.xml"
        self.path.write_text(EMPTY_FEED)

    def publish(self, tag):
        update_appcast(self.path, tag, SIGNATURE, 1234)

    def test_supported_tags_and_comparable_build_versions(self):
        for tag, channel, build in [
            ("v0.1.2-beta.1", "beta", "0.1.2b1"),
            ("0.1.2-beta.10", "beta", "0.1.2b10"),
            ("v0.1.2-rc.1", "rc", "0.1.2rc1"),
            ("v0.1.2", "stable", "0.1.2"),
            ("0.1.2", "stable", "0.1.2"),
        ]:
            with self.subTest(tag=tag):
                meta = release_metadata(tag)
                self.assertEqual(meta["channel"], channel)
                self.assertEqual(meta["build_version"], build)
                self.assertEqual(meta["prerelease"], str(channel != "stable").lower())
                self.assertEqual(meta["source_branch"], "main" if channel == "stable" else "develop")

    def test_invalid_tags_fail_instead_of_becoming_stable(self):
        for tag in ["v1.2.3-beta", "v1.2.3-beta.0", "v1.2.3-beta.bad", "v1.2.3-alpha.1", "v01.2.3", "v1.2", "v1.2.3-rc.1-extra", "v1.2.3\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_metadata(tag)

    def test_all_channels_preserved_and_stable_remains_unlabelled(self):
        for tag in ["0.1.1", "v0.1.2-beta.1", "v0.1.2-rc.1", "v0.1.2"]:
            self.publish(tag)
        items = ET.parse(self.path).getroot().find("channel").findall("item")
        self.assertEqual(len(items), 4)
        self.assertEqual([item.findtext(sparkle("channel")) for item in items], [None, "rc", "beta", None])
        self.assertEqual([item.findtext(sparkle("version")) for item in items], ["0.1.2", "0.1.2rc1", "0.1.2b1", "0.1.1"])
        self.assertEqual(items[2].findtext(sparkle("shortVersionString")), "0.1.2-beta.1")
        validate_appcast(ET.parse(self.path))

    def test_rerun_does_not_duplicate_version(self):
        self.publish("v0.1.2-beta.1")
        self.publish("v0.1.2-beta.1")
        self.assertEqual(len(ET.parse(self.path).getroot().find("channel").findall("item")), 1)

    def test_prerelease_without_channel_cannot_reach_stable_users(self):
        self.publish("v0.1.2-beta.1")
        tree = ET.parse(self.path)
        item = tree.getroot().find("channel/item")
        item.remove(item.find(sparkle("channel")))
        with self.assertRaisesRegex(ValueError, "incorrect or missing Sparkle channel"):
            validate_appcast(tree)

    def test_stable_entry_cannot_point_at_beta_archive(self):
        self.publish("v0.1.2")
        tree = ET.parse(self.path)
        tree.getroot().find("channel/item/enclosure").set("url", "https://github.com/nikita-moshyn/gamemode-macos/releases/download/v0.1.2-beta.1/GameMode-0.1.2-beta.1.zip")
        with self.assertRaisesRegex(ValueError, "download does not match"):
            validate_appcast(tree)

    def test_bad_metadata_never_overwrites_feed(self):
        before = self.path.read_bytes()
        for signature, length in [("invalid", 1234), (SIGNATURE, 0)]:
            with self.assertRaises(ValueError):
                update_appcast(self.path, "v0.1.2-beta.1", signature, length)
            self.assertEqual(self.path.read_bytes(), before)

    def test_bundle_version_must_match_appcast(self):
        app = Path(self.directory.name) / "GameMode.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        info = {
            "CFBundleVersion": "0.1.2b1",
            "CFBundleShortVersionString": "0.1.2-beta.1",
            "SUFeedURL": FEED_URL,
            "SUPublicEDKey": "test-public-key",
        }
        with (contents / "Info.plist").open("wb") as destination:
            plistlib.dump(info, destination)
        verify_bundle(app, "v0.1.2-beta.1")
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            verify_bundle(app, "v0.1.2-beta.2")


class FeedPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.remote = root / "remote.git"
        self.repo = root / "checkout"
        self.repo.mkdir()
        self.runner_temp = root / "runner"
        self.runner_temp.mkdir()
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("remote", "add", "origin", str(self.remote))
        (self.repo / "appcast.xml").write_text(EMPTY_FEED)
        (self.repo / "app.txt").write_text("stable code")
        self.git("add", ".")
        self.git("commit", "-m", "Initial stable source")
        self.git("push", "-u", "origin", "main")
        self.git("checkout", "-b", "develop")
        (self.repo / "app.txt").write_text("next release code")
        self.git("commit", "-am", "Next release")
        self.git("push", "-u", "origin", "develop")

    def git(self, *arguments):
        result = subprocess.run(["git", *arguments], cwd=self.repo, check=True, capture_output=True, text=True)
        return result.stdout

    def publish(self, tag):
        self.git("tag", tag)
        meta = release_metadata(tag)
        environment = dict(os.environ, TAG=tag, VERSION=meta["version"], ED_SIG=SIGNATURE, LENGTH="1234", RUNNER_TEMP=str(self.runner_temp))
        result = subprocess.run(["bash", str(Path(__file__).with_name("publish_appcast.sh"))], cwd=self.repo, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def items(self):
        return ET.fromstring(self.git("show", "origin/main:appcast.xml")).find("channel").findall("item")

    def test_beta_rc_and_stable_publish_only_feed_after_explicit_source_promotion(self):
        self.publish("v0.1.2-beta.1")
        self.assertEqual(self.git("show", "origin/main:app.txt"), "stable code")
        self.publish("v0.1.2-rc.1")
        self.assertEqual(self.git("show", "origin/main:app.txt"), "stable code")
        # Simulate merging the develop -> main PR before creating a stable tag.
        self.git("checkout", "main")
        self.git("merge", "--ff-only", "origin/main")
        self.git("merge", "--no-ff", "develop", "-m", "Promote tested release")
        self.git("push", "origin", "main")
        promoted = self.git("rev-parse", "origin/main").strip()
        self.publish("v0.1.2")
        self.assertEqual(self.git("show", "origin/main:app.txt"), "next release code")
        self.assertEqual(self.git("diff", "--name-only", promoted, "origin/main"), "appcast.xml\n")
        # develop still has its original empty appcast, so this also verifies
        # that publication reads main's feed instead of the tagged branch's.
        self.git("checkout", "develop")
        self.publish("v0.1.3-beta.1")
        self.assertEqual([item.findtext(sparkle("version")) for item in self.items()], ["0.1.3b1", "0.1.2", "0.1.2rc1", "0.1.2b1"])
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_rejected_push_is_retried_and_temporary_worktree_is_removed(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text('#!/bin/sh\nif [ ! -f retry-marker ]; then touch retry-marker; exit 1; fi\n')
        hook.chmod(0o755)
        self.publish("v0.1.2-beta.1")
        self.assertEqual(len(self.items()), 1)
        self.assertFalse((self.runner_temp / "appcast-checkout").exists())

    def test_stable_tag_on_unpromoted_develop_code_is_rejected(self):
        self.git("tag", "v0.1.2")
        with self.assertRaisesRegex(ValueError, "already merged into origin/main"):
            validate_source(self.repo, "v0.1.2")

    def test_beta_tag_on_unmerged_feature_code_is_rejected(self):
        self.git("checkout", "-b", "feature/unmerged")
        (self.repo / "app.txt").write_text("unmerged feature")
        self.git("commit", "-am", "Unmerged feature")
        self.git("tag", "v0.1.2-beta.1")
        with self.assertRaisesRegex(ValueError, "already merged into origin/develop"):
            validate_source(self.repo, "v0.1.2-beta.1")

    def test_annotated_tag_is_valid_when_branch_advances_after_tagging(self):
        self.git("tag", "-a", "v0.1.2-beta.1", "-m", "Beta snapshot")
        (self.repo / "app.txt").write_text("subsequent development")
        self.git("commit", "-am", "Develop continues")
        self.git("push", "origin", "develop")
        validate_source(self.repo, "v0.1.2-beta.1")


class SignatureVerificationTests(unittest.TestCase):
    def test_archive_key_signature_and_length_must_all_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "update.zip"
            archive.write_bytes(b"test release archive")
            swift = ["swift", "-module-cache-path", str(root / "ModuleCache")]
            # The ephemeral private key stays in memory and is never returned.
            generator = '''
import CryptoKit
import Foundation
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let key = Curve25519.Signing.PrivateKey()
let otherKey = Curve25519.Signing.PrivateKey()
let result = ["signature": try key.signature(for: archive).base64EncodedString(),
              "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
              "otherPublicKey": otherKey.publicKey.rawRepresentation.base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
            fixture = subprocess.run([*swift, "-e", generator, str(archive)], check=True, capture_output=True, text=True)
            metadata = json.loads(fixture.stdout)
            verifier = Path(__file__).with_name("verify_update.swift")

            def verify(public_key, length):
                return subprocess.run([*swift, str(verifier), str(archive), metadata["signature"], public_key, str(length)], capture_output=True, text=True)

            length = archive.stat().st_size
            self.assertEqual(verify(metadata["publicKey"], length).returncode, 0)
            self.assertNotEqual(verify(metadata["otherPublicKey"], length).returncode, 0)
            self.assertNotEqual(verify(metadata["publicKey"], length + 1).returncode, 0)
            archive.write_bytes(b"tampered release zip")
            self.assertEqual(archive.stat().st_size, length)
            self.assertNotEqual(verify(metadata["publicKey"], length).returncode, 0)


if __name__ == "__main__":
    unittest.main()
