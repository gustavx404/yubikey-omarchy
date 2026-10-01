#!/usr/bin/env python3
"""Short-lived stdin/stdout bridge between Omarchy and YubiKey Manager."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import re
import resource
import select
import subprocess
import sys
import time
import unicodedata
from typing import Any

from iconpacks import IconPackError, clear_aegis_pack, import_aegis_pack, load_aegis_pack

MAX_REQUEST_BYTES = 32 * 1024
MAX_PASSWORD_LENGTH = 1024
MAX_LABEL_LENGTH = 128
MAX_ACCOUNT_ID_LENGTH = 1024
VALID_KEY_ID = re.compile(r"^[A-Za-z0-9:_-]{1,128}$")
VALID_ACCOUNT_ID = re.compile(r"^(?:[0-9a-fA-F]{2}){1,512}$")
VALID_OTP = re.compile(r"^[0-9]{6,8}$")
VALID_TIMEOUTS = {30, 60, 120}
WL_COPY = "/usr/bin/wl-copy"
WL_PASTE = "/usr/bin/wl-paste"
ICON_ARCHIVE_PATH = "/run/omarchy-yubikey/icon-pack.zip"
ICON_STORAGE_PATH = "/run/omarchy-yubikey/custom-icons"


def emit(payload: dict[str, Any]) -> None:
    message = {"schema": 1, **payload}
    print(json.dumps(message, ensure_ascii=True, separators=(",", ":")), flush=True)


def harden_process() -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(4, 0, 0, 0, 0) != 0:  # PR_SET_DUMPABLE
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_DUMPABLE) failed")


def harden_child_process() -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(4, 0, 0, 0, 0) != 0:  # PR_SET_DUMPABLE
        os._exit(126)


def _object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_field")
        result[key] = value
    return result


def _reject_json_constant(_value: str) -> None:
    raise ValueError("invalid_json_constant")


def read_request(action: str) -> dict[str, Any]:
    raw = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
    if not raw or len(raw) > MAX_REQUEST_BYTES or not raw.endswith(b"\n"):
        raise ValueError("invalid_request_size")
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_object_without_duplicates,
            parse_constant=_reject_json_constant,
        )
    finally:
        del raw
    if sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1):
        raise ValueError("unexpected_request_data")
    if not isinstance(value, dict):
        raise ValueError("invalid_request")

    fields = {
        "list": {"schema", "passwords"},
        "code": {"schema", "keyId", "accountId", "password", "clearTimeoutSeconds"},
        "icon-import": {"schema"},
        "icon-list": {"schema"},
        "icon-clear": {"schema"},
    }.get(action)
    if fields is None or set(value) != fields or type(value["schema"]) is not int or value["schema"] != 1:
        raise ValueError("invalid_request_schema")

    if action in {"icon-import", "icon-list", "icon-clear"}:
        return value
    if action == "list":
        passwords = value["passwords"]
        if not isinstance(passwords, dict) or len(passwords) > 16:
            raise ValueError("invalid_password_map")
        for key_id, password in passwords.items():
            if not isinstance(key_id, str) or not VALID_KEY_ID.fullmatch(key_id):
                raise ValueError("invalid_key_id")
            if not isinstance(password, str) or len(password) > MAX_PASSWORD_LENGTH or _has_controls(password):
                raise ValueError("invalid_password")
    else:
        if not isinstance(value["keyId"], str) or not VALID_KEY_ID.fullmatch(value["keyId"]):
            raise ValueError("invalid_key_id")
        if not isinstance(value["accountId"], str) or len(value["accountId"]) > MAX_ACCOUNT_ID_LENGTH or not VALID_ACCOUNT_ID.fullmatch(value["accountId"]):
            raise ValueError("invalid_account_id")
        if not isinstance(value["password"], str) or len(value["password"]) > MAX_PASSWORD_LENGTH or _has_controls(value["password"]):
            raise ValueError("invalid_password")
        timeout = value["clearTimeoutSeconds"]
        if type(timeout) is not int or timeout not in VALID_TIMEOUTS:
            raise ValueError("invalid_timeout")
    return value


def _has_controls(value: str) -> bool:
    return any(unicodedata.category(char).startswith("C") for char in value)


def clean_label(value: Any, limit: int = MAX_LABEL_LENGTH) -> str:
    if not isinstance(value, str):
        return ""
    cleaned = "".join(
        char if not unicodedata.category(char).startswith("C") else " "
        for char in value
    )
    return " ".join(cleaned.split())[:limit]


def import_ykman() -> tuple[Any, ...]:
    try:
        from ykman.device import list_all_devices, scan_devices as scan_usb_devices
        from yubikit.core import TRANSPORT, USB_INTERFACE
        from yubikit.core.smartcard import SmartCardConnection
        from yubikit.management import CAPABILITY
        from yubikit.oath import OATH_TYPE, OathSession
    except ImportError as exc:
        raise RuntimeError("missing_dependency") from exc

    return (
        list_all_devices,
        scan_usb_devices,
        TRANSPORT,
        USB_INTERFACE,
        SmartCardConnection,
        CAPABILITY,
        OATH_TYPE,
        OathSession,
    )


def device_identity(info: Any, oath: Any) -> tuple[str, str]:
    serial = clean_label(str(info.serial) if info.serial is not None else "", 32)
    key_id = str(oath.device_id)
    if not VALID_KEY_ID.fullmatch(key_id):
        key_id = hashlib.sha256(key_id.encode("utf-8", errors="replace")).hexdigest()[:32]
    suffix = serial[-4:] if serial else clean_label(key_id[-4:], 4)
    version = clean_label(".".join(str(part) for part in info.version), 32)
    model = f"YubiKey {version}" if version else "YubiKey"
    return key_id, f"{model} ···· {suffix}"


def is_oath_capable(info: Any, transport: Any, capability: Any) -> bool:
    caps = info.supported_capabilities.get(transport.USB, capability(0))
    return bool(caps & capability.OATH)


def validate_password(oath: Any, raw_password: str) -> bool:
    secret = bytearray(raw_password.encode("utf-8"))
    derived_key = bytearray()
    password_text = ""
    try:
        password_text = secret.decode("utf-8")
        derived_key = bytearray(oath.derive_key(password_text))
        oath.validate(derived_key)
        return True
    except Exception:
        return False
    finally:
        password_text = ""
        secret[:] = b"\0" * len(secret)
        derived_key[:] = b"\0" * len(derived_key)


def list_accounts(request: dict[str, Any]) -> dict[str, Any]:
    (
        list_all_devices,
        _scan_usb_devices,
        transport,
        _usb_interface,
        connection_type,
        capability,
        _oath_type,
        oath_session,
    ) = import_ykman()

    groups: list[dict[str, Any]] = []
    passwords = request["passwords"]
    for device, info in list_all_devices(connection_types=(connection_type,)):
        if not is_oath_capable(info, transport, capability):
            continue

        try:
            with device.open_connection(connection_type) as connection:
                oath = oath_session(connection)
                key_id, title = device_identity(info, oath)
                group: dict[str, Any] = {
                    "keyId": key_id,
                    "title": title,
                    "accounts": [],
                    "locked": False,
                    "error": "",
                }

                if oath.has_key:
                    raw_password = passwords.pop(key_id, "")
                    if not raw_password:
                        group["locked"] = True
                        groups.append(group)
                        continue
                    accepted = validate_password(oath, raw_password)
                    raw_password = ""
                    if not accepted:
                        group["locked"] = True
                        group["error"] = "incorrect_password"
                        groups.append(group)
                        continue

                # Listing metadata must never advance an HOTP counter.
                for credential in oath.list_credentials():
                    if len(group["accounts"]) >= 256:
                        break
                    credential_type = credential.oath_type.name
                    if credential_type not in {"TOTP", "HOTP"}:
                        continue
                    group["accounts"].append(
                        {
                            "id": credential.id.hex(),
                            "issuer": clean_label(credential.issuer or ""),
                            "name": clean_label(credential.name),
                            "type": credential_type,
                            "period": max(1, min(int(credential.period or 30), 3600)),
                            "touchRequired": bool(credential.touch_required),
                        }
                    )
                groups.append(group)
        except Exception:
            version = clean_label(".".join(str(part) for part in info.version), 32)
            groups.append(
                {
                    "keyId": f"unavailable:{version.replace('.', '-') or 'unknown'}",
                    "title": f"YubiKey {version}" if version else "YubiKey",
                    "accounts": [],
                    "locked": False,
                    "error": "oath_unavailable",
                }
            )

    groups.sort(key=lambda group: (group["title"].lower(), group["keyId"]))
    return {"ok": True, "keys": groups}


def read_clipboard() -> bytes | None:
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [WL_PASTE, "--no-newline"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin", "HOME": "/nonexistent", **_wayland_environment()},
            preexec_fn=harden_child_process,
        )
        assert process.stdout is not None
        ready, _write, _error = select.select([process.stdout], [], [], 2)
        if not ready:
            process.kill()
            process.wait(timeout=1)
            return None
        value = os.read(process.stdout.fileno(), MAX_ACCOUNT_ID_LENGTH + 1)
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=1)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        return None
    return value if process.returncode == 0 else None


def _wayland_environment() -> dict[str, str]:
    keys = ("XDG_RUNTIME_DIR", "WAYLAND_DISPLAY")
    return {key: os.environ[key] for key in keys if os.environ.get(key)}


def copy_and_expire(code_buffer: bytearray, valid_to: int, code_type: str, timeout: int) -> bool:
    writer: subprocess.Popen[bytes] | None = None
    acknowledged = False
    try:
        writer = subprocess.Popen(
            [WL_COPY, "--foreground", "--sensitive", "--type", "text/plain;charset=utf-8"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin", "HOME": "/nonexistent", **_wayland_environment()},
            preexec_fn=harden_child_process,
        )
        assert writer.stdin is not None
        writer.stdin.write(code_buffer)
        writer.stdin.close()

        ready_deadline = time.monotonic() + 2
        while time.monotonic() < ready_deadline:
            if read_clipboard() == code_buffer:
                break
            if writer.poll() is not None:
                return False
            time.sleep(0.05)
        else:
            return False

        emit({"ok": True, "copied": True, "validTo": valid_to, "type": code_type})
        acknowledged = True
        duration = float(timeout)
        if code_type == "TOTP" and valid_to > 0:
            duration = min(duration, max(0.0, valid_to - time.time()))
        expires = time.monotonic() + duration

        while time.monotonic() < expires:
            if read_clipboard() != code_buffer:
                return True
            time.sleep(min(0.5, max(0.01, expires - time.monotonic())))

        if read_clipboard() == code_buffer:
            subprocess.run(
                [WL_COPY, "--clear"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                env={"PATH": "/usr/bin", "HOME": "/nonexistent", **_wayland_environment()},
                preexec_fn=harden_child_process,
            )
        return True
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return acknowledged
    finally:
        if writer is not None and writer.poll() is None:
            writer.terminate()
            try:
                writer.wait(timeout=1)
            except subprocess.TimeoutExpired:
                writer.kill()
                writer.wait(timeout=1)
        code_buffer[:] = b"\0" * len(code_buffer)


def generate_and_copy(request: dict[str, Any]) -> dict[str, Any]:
    (
        list_all_devices,
        _scan_usb_devices,
        transport,
        _usb_interface,
        connection_type,
        capability,
        _oath_type,
        oath_session,
    ) = import_ykman()

    wanted_key = request["keyId"]
    wanted_account = request["accountId"]
    raw_password = request.pop("password")

    for device, info in list_all_devices(connection_types=(connection_type,)):
        if not is_oath_capable(info, transport, capability):
            continue
        try:
            with device.open_connection(connection_type) as connection:
                oath = oath_session(connection)
                key_id, _title = device_identity(info, oath)
                if key_id != wanted_key:
                    continue
                if oath.has_key:
                    if not raw_password:
                        return {"ok": False, "error": "locked"}
                    password_for_validation = raw_password
                    raw_password = ""
                    accepted = validate_password(oath, password_for_validation)
                    password_for_validation = ""
                    if not accepted:
                        return {"ok": False, "error": "incorrect_password"}
                raw_password = ""

                credential = next(
                    (item for item in oath.list_credentials() if item.id.hex() == wanted_account),
                    None,
                )
                if credential is None:
                    return {"ok": False, "error": "account_missing"}

                result = oath.calculate_code(credential)
                code_buffer = bytearray(str(result.value).encode("ascii"))
                valid_to = int(result.valid_to or 0)
                code_type = credential.oath_type.name
                del result
                request["password"] = ""
                raw_password = ""
                if code_type not in {"TOTP", "HOTP"} or not VALID_OTP.fullmatch(code_buffer.decode("ascii", errors="ignore")):
                    code_buffer[:] = b"\0" * len(code_buffer)
                    return {"ok": False, "error": "invalid_code"}
                copied = copy_and_expire(code_buffer, valid_to, code_type, request["clearTimeoutSeconds"])
                if not copied:
                    return {"ok": False, "error": "clipboard_unavailable"}
                return {"ok": True, "copied": True, "validTo": valid_to, "type": code_type}
        except Exception as exc:
            if exc.__class__.__name__ == "ApplicationNotAvailableError":
                return {"ok": False, "error": "oath_unavailable"}
            if exc.__class__.__name__ == "TimeoutError":
                return {"ok": False, "error": "touch_timeout"}
            return {"ok": False, "error": "device_error"}

    return {"ok": False, "error": "key_disconnected"}


def scan_devices() -> dict[str, Any]:
    (
        _list_all_devices,
        scan_usb_devices,
        transport,
        usb_interface,
        _connection_type,
        _capability,
        _oath_type,
        _oath_session,
    ) = import_ykman()
    pids, state = scan_usb_devices()
    devices = [
        {
            "productId": int(pid),
            "model": clean_label(pid.yubikey_type.value, 64),
            "count": max(0, min(int(count), 32)),
        }
        for pid, count in pids.items()
        if pid.usb_interfaces & usb_interface.CCID
    ]
    devices.sort(key=lambda item: (item["model"], item["productId"]))
    return {"ok": True, "devices": devices, "state": int(state)}


def main() -> int:
    try:
        harden_process()
    except Exception:
        emit({"ok": False, "error": "hardening_unavailable"})
        return 1
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    try:
        if action == "scan":
            emit(scan_devices())
            return 0
        if action in {"icon-import", "icon-list", "icon-clear"}:
            read_request(action)
            if action == "icon-import":
                response = import_aegis_pack(ICON_ARCHIVE_PATH, ICON_STORAGE_PATH)
            elif action == "icon-list":
                response = load_aegis_pack(ICON_STORAGE_PATH)
            else:
                response = clear_aegis_pack(ICON_STORAGE_PATH)
            emit(response)
            return 0 if response.get("ok") else 1
        if action not in {"list", "code"}:
            raise ValueError("unknown_action")
        request = read_request(action)
        response = list_accounts(request) if action == "list" else generate_and_copy(request)
        if not response.get("copied"):
            emit(response)
        return 0 if response.get("ok") else 1
    except RuntimeError as exc:
        emit({"ok": False, "error": str(exc) if str(exc) == "missing_dependency" else "device_error"})
        return 1
    except IconPackError:
        emit({"ok": False, "error": "invalid_icon_pack"})
        return 1
    except Exception:
        emit({"ok": False, "error": "invalid_request"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
