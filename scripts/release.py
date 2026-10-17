#!/usr/bin/env python3
"""Release metadata and channel-safe Sparkle appcast publication."""

import argparse
import base64
import binascii
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "nikita-moshyn/gamemode-macos"
FEED_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/appcast.xml"
NUMBER = r"(?:0|[1-9][0-9]*)"
TAG_PATTERN = re.compile(rf"v?({NUMBER}\.{NUMBER}\.{NUMBER})(?:-(beta|rc)\.([1-9][0-9]*))?")
ET.register_namespace("sparkle", SPARKLE)


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def release_metadata(tag):
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ValueError(f"Invalid release tag: {tag}. Use vX.Y.Z, vX.Y.Z-beta.N, or vX.Y.Z-rc.N.")
    base, prerelease_channel, number = match.groups()
    channel = prerelease_channel or "stable"
    version = tag.removeprefix("v")
    # Sparkle's standard comparator ignores everything after a hyphen.
    # Keep the tag for display, but use comparable builds: beta < rc < stable.
    suffix = {"beta": f"b{number}", "rc": f"rc{number}", "stable": ""}[channel]
    label = {"beta": " (Beta)", "rc": " (Release Candidate)", "stable": ""}[channel]
    return {
        "tag": tag,
        "version": version,
        "build_version": base + suffix,
        "channel": channel,
        "prerelease": str(channel != "stable").lower(),
        "display_name": f"GameMode {version}{label}",
        "source_branch": "main",
    }


def manual_tag(version, channel, number):
    if not re.fullmatch(rf"{NUMBER}\.{NUMBER}\.{NUMBER}", version):
        raise ValueError("Version must have the form X.Y.Z, without a v prefix or channel suffix")
    if channel not in {"stable", "beta", "rc"}:
        raise ValueError("Channel must be stable, beta, or rc")
    if channel != "stable" and not re.fullmatch(r"[1-9][0-9]*", number):
        raise ValueError("Beta/RC number must be a positive integer")
    return f"v{version}" + (f"-{channel}.{number}" if channel != "stable" else "")


def validate_commit(commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Source commit must be a full, lowercase 40-character commit SHA; branch names can move on retries")
    return commit


def validate_source(repo, tag, commit=None):
    branch = release_metadata(tag)["source_branch"]
    source = validate_commit(commit) if commit is not None else f"refs/tags/{tag}"
    try:
        commit = subprocess.run(["git", "rev-parse", "--verify", f"{source}^{{commit}}"], cwd=repo, check=True, capture_output=True, text=True).stdout.strip()
        branch_ref = f"refs/remotes/origin/{branch}"
        subprocess.run(["git", "rev-parse", "--verify", f"{branch_ref}^{{commit}}"], cwd=repo, check=True, capture_output=True, text=True)
        result = subprocess.run(["git", "merge-base", "--is-ancestor", commit, branch_ref], cwd=repo, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Cannot resolve {source} or origin/{branch}; fetch the source commit and branch first") from error
    if result.returncode != 0:
        raise ValueError(f"{tag} must point to a commit already merged into origin/{branch}. Promote code through a PR before tagging.")
    return commit


def validate_signature(signature):
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Invalid Sparkle EdDSA signature encoding") from error
    if len(decoded) != 64:
        raise ValueError("A Sparkle EdDSA signature must contain 64 bytes")


def validate_appcast(tree):
    root = tree.getroot()
    if root.tag != "rss" or len(root.findall("channel")) != 1:
        raise ValueError("The appcast must contain one RSS channel")
    seen = set()
    for item in root.find("channel").findall("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Update item is missing its download enclosure")
        build = item.findtext(sparkle("version")) or enclosure.get(sparkle("version"))
        display = item.findtext(sparkle("shortVersionString")) or enclosure.get(sparkle("shortVersionString")) or build
        meta = release_metadata(display or "")
        if build != meta["build_version"]:
            raise ValueError(f"{display}: build version must be {meta['build_version']}, got {build}")
        expected_channel = None if meta["channel"] == "stable" else meta["channel"]
        if item.findtext(sparkle("channel")) != expected_channel:
            raise ValueError(f"{display}: incorrect or missing Sparkle channel; expected {expected_channel}")
        if build in seen:
            raise ValueError(f"Duplicate build in appcast: {build}")
        seen.add(build)
        validate_signature(enclosure.get(sparkle("edSignature"), ""))
        if int(enclosure.get("length", "0")) <= 0:
            raise ValueError(f"{display}: invalid archive length")
        # Validate the tag and asset against the display version, too. A stable
        # item must never point at a prerelease ZIP, regardless of its label.
        download = enclosure.get("url", "")
        prefix = f"https://github.com/{REPOSITORY}/releases/download/"
        if not download.startswith(prefix):
            raise ValueError(f"{display}: unexpected download URL")
        parts = download[len(prefix):].split("/")
        if len(parts) != 2:
            raise ValueError(f"{display}: invalid release asset URL")
        asset_meta = release_metadata(parts[0])
        if asset_meta["version"] != meta["version"] or parts[1] != f"GameMode-{meta['version']}.zip":
            raise ValueError(f"{display}: download does not match the update version")


def update_appcast(path, tag, signature, length):
    meta = release_metadata(tag)
    validate_signature(signature)
    if length <= 0:
        raise ValueError("Archive length must be positive")
    # The caller starts with the current feed from main, preserving all channels.
    tree = ET.parse(path)
    validate_appcast(tree)
    channel = tree.getroot().find("channel")
    for previous in list(channel.findall("item")):
        enclosure = previous.find("enclosure")
        build = previous.findtext(sparkle("version")) or enclosure.get(sparkle("version"))
        if build == meta["build_version"]:
            expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/GameMode-{meta['version']}.zip"
            if (enclosure.get("url"), enclosure.get(sparkle("edSignature")), enclosure.get("length")) != (expected_url, signature, str(length)):
                raise ValueError(f"{tag} is already in the feed with a different archive; publish a new version")
            # Keep the original publication date and avoid a feed commit on retries.
            return
    item = ET.Element("item")
    ET.SubElement(item, "title").text = meta["display_name"]
    ET.SubElement(item, sparkle("version")).text = meta["build_version"]
    ET.SubElement(item, sparkle("shortVersionString")).text = meta["version"]
    if meta["channel"] != "stable":
        ET.SubElement(item, sparkle("channel")).text = meta["channel"]
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPOSITORY}/releases/download/{tag}/GameMode-{meta['version']}.zip",
        "length": str(length),
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = "14.0"
    language = channel.find("language")
    channel.insert(list(channel).index(language) + 1 if language is not None else 0, item)
    validate_appcast(tree)
    ET.indent(tree, space="    ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def verify_bundle(app, tag):
    meta = release_metadata(tag)
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    for key, value in {
        "CFBundleVersion": meta["build_version"],
        "CFBundleShortVersionString": meta["version"],
        "SUFeedURL": FEED_URL,
        "GameModeReleaseChannel": meta["channel"],
    }.items():
        if info.get(key) != value:
            raise ValueError(f"{key}: expected {value}, got {info.get(key)}")
    if not info.get("SUPublicEDKey"):
        raise ValueError("The app is missing its Sparkle public key")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata = commands.add_parser("metadata")
    metadata.add_argument("tag")
    metadata.add_argument("--github-output", type=Path)
    source = commands.add_parser("validate-source")
    source.add_argument("--tag", required=True)
    source.add_argument("--repo", type=Path, default=Path.cwd())
    source.add_argument("--commit")
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--channel", required=True)
    prepare.add_argument("--number", default="1")
    prepare.add_argument("--commit", required=True)
    prepare.add_argument("--repo", type=Path, default=Path.cwd())
    prepare.add_argument("--github-output", type=Path, required=True)
    appcast = commands.add_parser("appcast")
    appcast.add_argument("--path", type=Path, required=True)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--length", type=int, required=True)
    validate = commands.add_parser("validate-appcast")
    validate.add_argument("path", type=Path)
    bundle = commands.add_parser("verify-bundle")
    bundle.add_argument("--app", type=Path, required=True)
    bundle.add_argument("--tag", required=True)
    args = parser.parse_args()
    try:
        if args.command == "metadata":
            output = "".join(f"{key}={value}\n" for key, value in release_metadata(args.tag).items())
            if args.github_output:
                with args.github_output.open("a") as destination:
                    destination.write(output)
            else:
                print(output, end="")
        elif args.command == "appcast":
            update_appcast(args.path, args.tag, args.signature, args.length)
        elif args.command == "validate-source":
            validate_source(args.repo, args.tag, args.commit)
        elif args.command == "prepare":
            tag = manual_tag(args.version, args.channel, args.number)
            commit = validate_source(args.repo, tag, args.commit)
            metadata = {**release_metadata(tag), "commit": commit}
            with args.github_output.open("a") as destination:
                destination.write("".join(f"{key}={value}\n" for key, value in metadata.items()))
        elif args.command == "validate-appcast":
            validate_appcast(ET.parse(args.path))
        elif args.command == "verify-bundle":
            verify_bundle(args.app, args.tag)
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f"Release validation failed: {error}\n")


if __name__ == "__main__":
    main()
