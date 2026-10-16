#!/usr/bin/env python3
"""Persist and resume a release without replacing published binaries."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from release import REPOSITORY, release_metadata, validate_commit, validate_signature


MANIFEST = "release.json"


class DownloadRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        redirected = super().redirect_request(request, fp, code, message, headers, new_url)
        if urlsplit(new_url).scheme != "https":
            raise ValueError("Refusing an insecure download redirect")
        if urlsplit(new_url).netloc != urlsplit(request.full_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self):
        self.token = os.environ["GH_TOKEN"]
        self.opener = build_opener(DownloadRedirect())

    def request(self, path, method="GET", data=None, binary=False, missing_ok=False, upload=False):
        host = "uploads.github.com" if upload else "api.github.com"
        headers = {"Authorization": f"Bearer {self.token}", "X-GitHub-Api-Version": "2022-11-28",
                   "Accept": "application/octet-stream" if binary else "application/vnd.github+json"}
        if data is not None:
            headers["Content-Type"] = "application/octet-stream" if upload else "application/json"
            if not upload:
                data = json.dumps(data).encode()
        request = Request(f"https://{host}/repos/{REPOSITORY}/{path}", data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                body = response.read()
        except HTTPError as error:
            if error.code == 404 and missing_ok:
                return None
            raise ValueError(f"GitHub {method} {path} failed (HTTP {error.code}); retry after resolving the error") from error
        return body if binary else (json.loads(body) if body else None)

    def release(self, tag):
        return self.request(f"releases/tags/{tag}", missing_ok=True)

    def assets(self, release):
        result = []
        page = 1
        while True:
            assets = self.request(f"releases/{release['id']}/assets?per_page=100&page={page}")
            result.extend(assets)
            if len(assets) < 100:
                return {asset["name"]: asset for asset in result}
            page += 1

    def download(self, asset):
        return self.request(f"releases/assets/{asset['id']}", binary=True)

    def upload(self, release, path):
        return self.request(f"releases/{release['id']}/assets?{urlencode({'name': path.name})}",
                            method="POST", data=path.read_bytes(), upload=True)

    def tag_commit(self, tag):
        ref = self.request(f"git/ref/tags/{tag}", missing_ok=True)
        if ref is None:
            return None
        obj = ref["object"]
        for _ in range(10):
            if obj["type"] == "commit":
                return obj["sha"]
            if obj["type"] != "tag":
                break
            obj = self.request(f"git/tags/{obj['sha']}")["object"]
        raise ValueError(f"{tag} does not resolve to a commit")

    def artifact(self, run_id):
        name = f"release-{run_id}"
        page = 1
        while True:
            batch = self.request(f"actions/runs/{run_id}/artifacts?per_page=100&page={page}")["artifacts"]
            for item in batch:
                if item["name"] == name and not item["expired"]:
                    return item
            if len(batch) < 100:
                return None
            page += 1


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def archive_name(tag):
    return f"GameMode-{release_metadata(tag)['version']}.zip"


def record(directory, tag, commit, signature, length):
    validate_commit(commit)
    validate_signature(signature)
    archive = directory / archive_name(tag)
    if length <= 0 or archive.stat().st_size != length:
        raise ValueError("Archive size does not match the verified Sparkle signature metadata")
    manifest = {**release_metadata(tag), "schema": 1, "commit": commit, "archive": archive.name,
                "signature": signature, "length": length, "sha256": digest(archive)}
    (directory / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def verify(directory, tag, commit):
    validate_commit(commit)
    manifest = json.loads((directory / MANIFEST).read_text())
    expected = {**release_metadata(tag), "schema": 1, "commit": commit, "archive": archive_name(tag)}
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"Release manifest {key} mismatch; refusing to reuse a different build")
    validate_signature(manifest.get("signature", ""))
    archive = directory / expected["archive"]
    if manifest.get("length", 0) <= 0 or archive.stat().st_size != manifest["length"] or digest(archive) != manifest.get("sha256"):
        raise ValueError("Release archive checksum or length mismatch")
    return manifest


def inspect_version(client, tag, commit):
    # Legacy unprefixed tags represent the same version and must not be republished.
    alias = tag.removeprefix("v") if tag.startswith("v") else "v" + tag
    if client.tag_commit(alias) is not None or client.release(alias) is not None:
        raise ValueError(f"Version already exists as {alias}; use a new version")
    target = client.tag_commit(tag)
    if target is not None and target != commit:
        raise ValueError(f"{tag} already identifies a different commit; tags are never moved")
    return client.release(tag), target


def download_release(client, release, directory, tag, commit, published_only=False):
    if published_only and release["draft"]:
        raise ValueError("The release is still a draft; finish publication before updating the feed")
    if client.tag_commit(tag) != commit:
        raise ValueError("Release tag does not match the requested source commit")
    assets = client.assets(release)
    directory.mkdir(parents=True, exist_ok=True)
    for name in (MANIFEST, archive_name(tag)):
        if name not in assets:
            raise ValueError(f"Release is missing {name}; rerun the original workflow to resume its saved artifact")
        (directory / name).write_bytes(client.download(assets[name]))
    return verify(directory, tag, commit)


def restore(client, directory, tag, commit, run_id):
    release, _ = inspect_version(client, tag, commit)
    if client.artifact(run_id) is not None:
        return {"artifact_exists": "true", "restored": "true"}
    if release is not None:
        download_release(client, release, directory, tag, commit)
        return {"artifact_exists": "false", "restored": "true"}
    return {"artifact_exists": "false", "restored": "false"}


def publish(client, directory, tag, commit):
    manifest = verify(directory, tag, commit)
    release, target = inspect_version(client, tag, commit)
    if target is None:
        client.request("git/refs", method="POST", data={"ref": f"refs/tags/{tag}", "sha": commit})
    if release is None:
        release = client.request("releases", method="POST", data={
            "tag_name": tag, "target_commitish": commit, "name": manifest["display_name"], "draft": True,
            "prerelease": manifest["prerelease"] == "true",
            "body": f"Download {manifest['archive']}, unzip, and drag GameMode.app to Applications.\n\n"
                    f"Signed with Developer ID and notarized by Apple.\n\nSource commit: `{commit}`\n",
        })
    if release["prerelease"] != (manifest["prerelease"] == "true"):
        raise ValueError("Existing release has a conflicting channel")
    assets = client.assets(release)
    # Compare both existing files before uploading anything. Never use clobber.
    for name in (MANIFEST, manifest["archive"]):
        if name in assets:
            if release["draft"] and assets[name].get("state") == "starter":
                continue  # GitHub can leave an empty starter after a failed upload.
            if hashlib.sha256(client.download(assets[name])).hexdigest() != digest(directory / name):
                raise ValueError(f"Existing {name} differs from this build; publish a new version")
        elif not release["draft"]:
            raise ValueError(f"Published release is missing {name}; published releases are never modified")
    for name in (MANIFEST, manifest["archive"]):
        if name in assets and release["draft"] and assets[name].get("state") == "starter":
            client.request(f"releases/assets/{assets[name]['id']}", method="DELETE")
            del assets[name]
        if name not in assets:
            client.upload(release, directory / name)
    # Verify bytes from GitHub before making the release visible to users.
    with tempfile.TemporaryDirectory() as temporary:
        downloaded = download_release(client, release, Path(temporary), tag, commit)
        if downloaded != manifest:
            raise ValueError("Uploaded release manifest changed unexpectedly")
    if release["draft"]:
        client.request(f"releases/{release['id']}", method="PATCH", data={
            "draft": False, "make_latest": "true" if manifest["channel"] == "stable" else "false",
        })
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["record", "verify", "restore", "publish", "download"])
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--signature")
    parser.add_argument("--length", type=int)
    parser.add_argument("--run-id")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        validate_commit(args.commit)
        release_metadata(args.tag)
        if args.command == "record":
            if args.signature is None or args.length is None:
                raise ValueError("record requires --signature and --length")
            result = record(args.directory, args.tag, args.commit, args.signature, args.length)
        elif args.command == "verify":
            result = verify(args.directory, args.tag, args.commit)
        elif args.command == "restore":
            if not args.run_id or not args.run_id.isdigit():
                raise ValueError("restore requires a numeric --run-id")
            result = restore(GitHub(), args.directory, args.tag, args.commit, args.run_id)
        elif args.command == "publish":
            result = publish(GitHub(), args.directory, args.tag, args.commit)
        else:
            client = GitHub()
            release, _ = inspect_version(client, args.tag, args.commit)
            if release is None:
                raise ValueError("No published release exists")
            result = download_release(client, release, args.directory, args.tag, args.commit, published_only=True)
        if args.github_output:
            # Only allow known, validated fields into the Actions output protocol.
            keys = {"artifact_exists", "restored", "signature", "length"}
            with args.github_output.open("a") as destination:
                destination.write("".join(f"{key}={value}\n" for key, value in result.items() if key in keys))
        print(f"Release {args.command} completed: {args.tag} ({args.commit})")
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"Release delivery failed: {error}\n")


if __name__ == "__main__":
    main()
