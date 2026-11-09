"""Find My People bootstrap artifacts: names, formats, and private-file I/O.

The app reads and writes the same files in
App/Location/FindMyPeople/FindMyPeopleBootstrap.swift, and
iMCPTests/FindMyPeopleBootstrapTests.swift fails when a constant here stops
matching it. The on-disk format must not change: a handoff or envelope written
by an earlier version still has to import.

Standard library only, and no import of anything beside it: the LLDB capture
loads this file by absolute path, and the security verifier runs it as root
with `python3 -I`.

Run as a script:
  find_my_people_artifacts.py path APP_SUPPORT_DIR KIND
  find_my_people_artifacts.py check-handoff HANDOFF_JSON
  find_my_people_artifacts.py report MODE OUTPUT ENVELOPE FULL_SECURITY DEVELOPER BOOT_UUID
"""

import hashlib
import json
import os
import secrets
import stat
import sys
import uuid


HANDOFF_FORMAT = "imcp-find-my-people-handoff-v1"
ENVELOPE_FORMAT = "imcp-find-my-people-envelope-v1"
# The baseline and the restoration report share one format; the app checks both
# against it.
REPORT_FORMAT = "imcp-find-my-people-restoration-v1"
PAYLOAD_MAGIC = b"iMCPFMP1"

# Relative to ~/Library/Application Support.
ARTIFACT_DIRECTORY = "iMCP/FindMyPeopleBootstrap"
HANDOFF_NAME = "handoff.json"
ENVELOPE_NAME = "envelope.json"
BASELINE_NAME = "baseline.json"
RESTORATION_NAME = "restoration.json"

HANDOFF_KEYS = ("format", "nonce", "baseline_digest", "installation_binding", "public_key_pem")
# Present in every handoff the app writes; older ones may lack it.
HANDOFF_OPTIONAL_KEYS = ("prepared_at",)
ENVELOPE_KEYS = ("format", "nonce", "baseline_digest", "installation_binding", "ciphertext")
REPORT_KEYS = ("format", "authoritative", "baselineDigest", "envelopeDigest", "posture")
POSTURE_KEYS = ("fullSecurityEnabled", "sipEnabled", "authenticatedRootEnabled", "unsafeBootArguments", "developerToolsSecurityEnabled", "bootSessionUUID")

MAXIMUM_ARTIFACT_BYTES = 16_384

_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def artifact_path(app_support_directory, kind):
    names = {
        "directory": "",
        "handoff": HANDOFF_NAME,
        "envelope": ENVELOPE_NAME,
        "baseline": BASELINE_NAME,
        "restoration": RESTORATION_NAME,
    }
    directory = os.path.join(app_support_directory, ARTIFACT_DIRECTORY)
    return os.path.join(directory, names[kind]) if names[kind] else directory


def entry_exists(directory_descriptor, name):
    try:
        os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def open_private_directory(path, uid, gid):
    """Opens a directory that is not a symlink, owned by uid:gid, mode 0700.

    Raises OSError when it cannot be opened and RuntimeError when it is unsafe.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | _NOFOLLOW)
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != uid
        or metadata.st_gid != gid
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        os.close(descriptor)
        raise RuntimeError("unsafe artifact directory")
    return descriptor


def read_private_file(directory_descriptor, name, uid, gid):
    """Reads a regular, non-symlink file owned by uid:gid with mode 0600."""
    descriptor = os.open(name, os.O_RDONLY | os.O_CLOEXEC | _NOFOLLOW, dir_fd=directory_descriptor)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid or metadata.st_gid != gid:
            raise RuntimeError("invalid artifact owner or type")
        if (
            stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size <= 0
            or metadata.st_size > MAXIMUM_ARTIFACT_BYTES
        ):
            raise RuntimeError("invalid artifact permissions or size")
        chunks = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 4096))
            if not chunk:
                raise RuntimeError("short artifact read")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def publish_private_file(directory_descriptor, name, payload, uid, gid):
    """Writes payload as uid:gid mode 0600 and publishes it under name.

    Refuses every pre-existing entry at name, including a dangling symlink
    created after the caller checked: the complete, durable temporary file is
    hard-linked into place, which never replaces anything.
    """
    temporary = f".{name}-{secrets.token_hex(12)}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | _NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600, dir_fd=directory_descriptor)
    try:
        try:
            os.fchown(descriptor, uid, gid)
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise RuntimeError("short artifact write")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.link(
            temporary,
            name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        os.unlink(temporary, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
    except BaseException:
        try:
            os.unlink(temporary, dir_fd=directory_descriptor)
        except FileNotFoundError:
            pass
        raise


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def is_valid_handoff(handoff):
    if (
        not isinstance(handoff, dict)
        or set(handoff) - set(HANDOFF_OPTIONAL_KEYS) != set(HANDOFF_KEYS)
        or handoff.get("format") != HANDOFF_FORMAT
        or not isinstance(handoff.get("nonce"), str)
        or not isinstance(handoff.get("baseline_digest"), str)
        or len(handoff["baseline_digest"]) != 64
        or not isinstance(handoff.get("installation_binding"), str)
        or len(handoff["installation_binding"]) != 64
        or not isinstance(handoff.get("public_key_pem"), str)
    ):
        return False
    try:
        uuid.UUID(handoff["nonce"])
        return (
            len(bytes.fromhex(handoff["baseline_digest"])) == 32
            and len(bytes.fromhex(handoff["installation_binding"])) == 32
        )
    except (ValueError, TypeError):
        return False


def read_handoff(directory_descriptor, uid, gid):
    """Returns the validated handoff, or raises."""
    handoff = json.loads(read_private_file(directory_descriptor, HANDOFF_NAME, uid, gid).decode("utf-8"))
    if not is_valid_handoff(handoff):
        raise RuntimeError("invalid handoff")
    return handoff


def envelope_for(handoff, ciphertext_base64):
    return {
        "format": ENVELOPE_FORMAT,
        "nonce": handoff["nonce"],
        "baseline_digest": handoff["baseline_digest"],
        "installation_binding": handoff["installation_binding"],
        "ciphertext": ciphertext_base64,
    }


def payload_for(handoff, key):
    return b"".join(
        [
            PAYLOAD_MAGIC,
            bytes.fromhex(handoff["nonce"].replace("-", "")),
            bytes.fromhex(handoff["baseline_digest"]),
            bytes.fromhex(handoff["installation_binding"]),
            key,
        ]
    )


def write_report(mode, output, envelope, full_security, developer, boot_uuid, uid, gid):
    """Publishes the metadata-only baseline or restoration report."""
    output = os.path.abspath(output)
    expected_output = BASELINE_NAME if mode == "baseline" else RESTORATION_NAME
    if mode not in ("baseline", "restoration") or os.path.basename(output) != expected_output:
        raise RuntimeError("unexpected report name")
    directory = os.path.dirname(output)
    directory_descriptor = open_private_directory(directory, uid, gid)
    try:
        if entry_exists(directory_descriptor, expected_output):
            raise RuntimeError("report entry already exists")

        envelope_digest = ""
        if mode == "restoration":
            envelope = os.path.abspath(envelope)
            if os.path.dirname(envelope) != directory or os.path.basename(envelope) != ENVELOPE_NAME:
                raise RuntimeError("unexpected envelope location")
            envelope_digest = hashlib.sha256(
                read_private_file(directory_descriptor, ENVELOPE_NAME, uid, gid)
            ).hexdigest()

        posture = {
            "fullSecurityEnabled": full_security,
            "sipEnabled": True,
            "authenticatedRootEnabled": True,
            "unsafeBootArguments": [],
            "developerToolsSecurityEnabled": developer,
            "bootSessionUUID": boot_uuid,
        }
        stable = dict(posture)
        stable["bootSessionUUID"] = ""
        digest = hashlib.sha256(
            json.dumps(stable, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        report = {
            "format": REPORT_FORMAT,
            "authoritative": False,
            "baselineDigest": digest,
            "envelopeDigest": envelope_digest,
            "posture": posture,
        }
        publish_private_file(directory_descriptor, expected_output, canonical_json(report), uid, gid)
    finally:
        os.close(directory_descriptor)


def _report_command(arguments):
    mode, output, envelope, full_security, developer, boot_uuid = arguments
    try:
        uid = int(os.environ["SUDO_UID"])
        gid = int(os.environ["SUDO_GID"])
        write_report(
            mode,
            output,
            envelope,
            full_security == "true",
            developer == "true",
            boot_uuid,
            uid,
            gid,
        )
    except BaseException:
        print("refusing unsafe or unavailable verification artifact", file=sys.stderr)
        return 1
    return 0


def _check_handoff_command(arguments):
    (path,) = arguments
    path = os.path.abspath(path)
    try:
        if os.path.basename(path) != HANDOFF_NAME:
            raise RuntimeError("unexpected handoff name")
        directory_descriptor = open_private_directory(os.path.dirname(path), os.getuid(), os.getgid())
        try:
            read_handoff(directory_descriptor, os.getuid(), os.getgid())
        finally:
            os.close(directory_descriptor)
    except BaseException:
        print("the prepared handoff is invalid; prepare setup in iMCP again", file=sys.stderr)
        return 1
    return 0


def main(argv):
    commands = {
        "path": (2, lambda arguments: print(artifact_path(*arguments)) or 0),
        "check-handoff": (1, _check_handoff_command),
        "report": (6, _report_command),
    }
    if len(argv) < 1 or argv[0] not in commands or len(argv) - 1 != commands[argv[0]][0]:
        print(__doc__.split("Run as a script:")[1].strip(), file=sys.stderr)
        return 2
    return commands[argv[0]][1](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
