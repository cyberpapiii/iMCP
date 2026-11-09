"""Importable LLDB command for one bounded Find My People key capture.

Adapted from findmy-key-extractor commit
3797fbb99e033a474b5c3ef54a60601cc24ee7b1 (MIT). This command accepts only
the canonical Apple agent, sqlite3_key_v2, the main LocalStorage database, and
a 32-byte key. It writes RSA-OAEP ciphertext; key bytes are never printed or
written as plaintext.
"""

import base64
import importlib.util
import os
import shlex
import subprocess
import tempfile

import lldb


def _load_artifacts():
    # By absolute path, never through sys.path: this runs inside a root
    # debugger, and a same-named module earlier on the path would run with it.
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "find_my_people_artifacts.py")
    spec = importlib.util.spec_from_file_location("find_my_people_artifacts", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


artifacts = _load_artifacts()

CANONICAL_EXECUTABLE = "/usr/libexec/findmylocateagent"
DATABASE_SUFFIX = "/LocalStorage.db"
captured = False
configuration = None


def _invoking_user():
    try:
        uid = int(os.environ["SUDO_UID"])
        gid = int(os.environ["SUDO_GID"])
    except (KeyError, TypeError, ValueError):
        raise RuntimeError("capture requires an explicit sudo invocation")
    if uid <= 0 or gid < 0:
        raise RuntimeError("capture requires a non-root invoking user")
    return uid, gid


def _close_configuration():
    global configuration
    if configuration is not None:
        descriptor = configuration.get("directory_descriptor")
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    configuration = None


def _read_c_string(process, address, limit=4096):
    error = lldb.SBError()
    value = process.ReadCStringFromMemory(address, limit, error)
    return value if error.Success() else None


def _argument(frame, arm64, index):
    names = ("x0", "x1", "x2", "x3") if arm64 else ("rdi", "rsi", "rdx", "rcx")
    return frame.FindRegister(names[index]).GetValueAsUnsigned()


def _encrypt(public_pem, payload):
    converted = subprocess.run(
        ["/usr/bin/openssl", "rsa", "-RSAPublicKey_in", "-pubout"],
        input=public_pem.encode("ascii"),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
        timeout=10,
    ).stdout
    with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", delete=False) as public_file:
        public_file.write(converted.decode("ascii"))
        public_path = public_file.name
    try:
        result = subprocess.run(
            [
                "/usr/bin/openssl",
                "pkeyutl",
                "-encrypt",
                "-pubin",
                "-inkey",
                public_path,
                "-pkeyopt",
                "rsa_padding_mode:oaep",
                "-pkeyopt",
                "rsa_oaep_md:sha256",
                "-pkeyopt",
                "rsa_mgf1_md:sha256",
            ],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=10,
        )
        return result.stdout
    finally:
        os.unlink(public_path)


def _write_envelope(ciphertext):
    handoff = configuration["handoff"]
    envelope = artifacts.envelope_for(handoff, base64.b64encode(ciphertext).decode("ascii"))
    artifacts.publish_private_file(
        configuration["directory_descriptor"],
        artifacts.ENVELOPE_NAME,
        artifacts.canonical_json(envelope),
        configuration["uid"],
        configuration["gid"],
    )


def _breakpoint(frame, location, _dictionary):
    global captured
    if captured:
        return False
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    arm64 = "arm64" in target.GetTriple()
    database_name = _read_c_string(process, _argument(frame, arm64, 1))
    key_address = _argument(frame, arm64, 2)
    key_length = _argument(frame, arm64, 3)
    if database_name != "main" or key_length != 32 or key_address == 0:
        return False

    database_expression = frame.EvaluateExpression(
        "(const char *)sqlite3_db_filename((sqlite3 *)$x0, (const char *)$x1)"
        if arm64
        else "(const char *)sqlite3_db_filename((sqlite3 *)$rdi, (const char *)$rsi)"
    )
    database_path = _read_c_string(process, database_expression.GetValueAsUnsigned())
    if not database_path or not database_path.endswith(DATABASE_SUFFIX):
        return False
    if "findmylocateagent" not in database_path or "LocalStorage.db" not in database_path:
        return False

    error = lldb.SBError()
    key = process.ReadMemory(key_address, 32, error)
    if not error.Success() or len(key) != 32:
        return False
    try:
        handoff = configuration["handoff"]
        payload = artifacts.payload_for(handoff, key)
        _write_envelope(_encrypt(handoff["public_key_pem"], payload))
        key = b"\0" * 32
        captured = True
        print("Captured one encrypted LocalStorage key envelope; no key bytes were printed.")
    except BaseException:
        print("Encrypted key capture failed; no key bytes were printed.")
    finally:
        target.BreakpointDelete(location.GetBreakpoint().GetID())
        _close_configuration()
    # Stop once so batch LLDB can run its descriptor cleanup commands, detach,
    # and quit. Non-matching sqlite3_key_v2 calls still auto-continue above.
    return True


def capture(debugger, command, result, _dictionary):
    global configuration
    arguments = shlex.split(command)
    if len(arguments) != 2:
        result.SetError("usage: imcp_find_my_people_capture HANDOFF_JSON ENVELOPE_JSON")
        return
    target = debugger.GetSelectedTarget()
    executable = target.GetExecutable().GetPath()
    if executable != CANONICAL_EXECUTABLE:
        result.SetError("refusing non-canonical target")
        return
    handoff_path = os.path.abspath(arguments[0])
    output_path = os.path.abspath(arguments[1])
    if (
        os.path.basename(handoff_path) != artifacts.HANDOFF_NAME
        or os.path.basename(output_path) != artifacts.ENVELOPE_NAME
    ):
        result.SetError("refusing unexpected artifact names")
        return
    artifact_directory = os.path.dirname(handoff_path)
    if artifact_directory != os.path.dirname(output_path):
        result.SetError("artifacts must share one private directory")
        return
    try:
        uid, gid = _invoking_user()
    except RuntimeError:
        result.SetError("capture requires an explicit sudo invocation")
        return
    try:
        directory_descriptor = artifacts.open_private_directory(artifact_directory, uid, gid)
    except OSError:
        result.SetError("private artifact directory is unavailable")
        return
    except RuntimeError:
        result.SetError("private artifact directory has unsafe ownership or permissions")
        return
    try:
        handoff = artifacts.read_handoff(directory_descriptor, uid, gid)
    except BaseException:
        os.close(directory_descriptor)
        result.SetError("invalid handoff")
        return
    if artifacts.entry_exists(directory_descriptor, artifacts.ENVELOPE_NAME):
        os.close(directory_descriptor)
        result.SetError("refusing to overwrite an existing envelope entry")
        return
    configuration = {
        "handoff": handoff,
        "directory_descriptor": directory_descriptor,
        "uid": uid,
        "gid": gid,
    }
    breakpoint = target.BreakpointCreateByName("sqlite3_key_v2")
    if not breakpoint.IsValid() or breakpoint.GetNumLocations() == 0:
        _close_configuration()
        result.SetError("sqlite3_key_v2 was not found")
        return
    breakpoint.SetScriptCallbackFunction("find_my_people_key._breakpoint")
    result.AppendMessage("Armed one LocalStorage sqlite3_key_v2 capture; trigger a Find My People refresh.")


def __lldb_init_module(debugger, _dictionary):
    debugger.HandleCommand("command script add -f find_my_people_key.capture imcp_find_my_people_capture")
