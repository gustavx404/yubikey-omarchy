#!/usr/bin/env python3
"""Small stdin/stdout bridge between the Omarchy widget and YubiKey Manager."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from typing import Any


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def read_request() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        return {}
    value = json.loads(line)
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def import_ykman() -> tuple[Any, ...]:
    try:
        from ykman.device import list_all_devices, scan_devices
        from yubikit.core import TRANSPORT, USB_INTERFACE
        from yubikit.core.smartcard import SmartCardConnection
        from yubikit.management import CAPABILITY
        from yubikit.oath import OATH_TYPE, OathSession
    except ImportError as exc:
        raise RuntimeError("missing_dependency") from exc

    return (
        list_all_devices,
        scan_devices,
        TRANSPORT,
        USB_INTERFACE,
        SmartCardConnection,
        CAPABILITY,
        OATH_TYPE,
        OathSession,
    )


def device_identity(info: Any, oath: Any) -> tuple[str, str]:
    serial = str(info.serial) if info.serial is not None else ""
    # This stable, key-derived ID avoids writing the hardware serial to the
    # widget's local alias settings.
    key_id = str(oath.device_id)
    suffix = serial[-4:] if serial else key_id[-4:]
    version = ".".join(str(part) for part in info.version)
    model = f"YubiKey {version}" if version else "YubiKey"
    return key_id, f"{model} ···· {suffix}"


def is_oath_capable(info: Any, transport: Any, capability: Any) -> bool:
    caps = info.supported_capabilities.get(transport.USB, capability(0))
    return bool(caps & capability.OATH)


def list_accounts(request: dict[str, Any]) -> dict[str, Any]:
    (
        list_all_devices,
        _scan_devices,
        transport,
        _usb_interface,
        connection_type,
        capability,
        oath_type,
        oath_session,
    ) = import_ykman()

    groups: list[dict[str, Any]] = []
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
                    passwords = request.get("passwords", {})
                    password = passwords.get(key_id, "") if isinstance(passwords, dict) else ""
                    if not password:
                        group["locked"] = True
                        groups.append(group)
                        continue
                    try:
                        oath.validate(oath.derive_key(str(password)))
                    except Exception:
                        group["locked"] = True
                        group["error"] = "incorrect_password"
                        groups.append(group)
                        continue

                # Read credential metadata only. In particular, do not call
                # calculate_all() while listing: calculating HOTP advances
                # its counter, and opening the panel must never consume one.
                for credential in oath.list_credentials():
                    group["accounts"].append(
                        {
                            "id": credential.id.hex(),
                            "issuer": credential.issuer or "",
                            "name": credential.name,
                            "type": credential.oath_type.name,
                            "period": credential.period,
                            "touchRequired": bool(credential.touch_required),
                        }
                    )
                groups.append(group)
        except Exception:
            # A connected CCID interface can still have OATH disabled. Keep
            # other keys visible and report this one as unavailable.
            version = ".".join(str(part) for part in info.version)
            groups.append(
                {
                    "keyId": f"unavailable:{version or 'unknown'}",
                    "title": f"YubiKey {version}" if version else "YubiKey",
                    "accounts": [],
                    "locked": False,
                    "error": "oath_unavailable",
                }
            )

    groups.sort(key=lambda group: (group["title"].lower(), group["keyId"]))
    return {"ok": True, "keys": groups}


def generate_code(request: dict[str, Any]) -> dict[str, Any]:
    (
        list_all_devices,
        _scan_devices,
        transport,
        _usb_interface,
        connection_type,
        capability,
        _oath_type,
        oath_session,
    ) = import_ykman()

    wanted_key = str(request.get("keyId", ""))
    wanted_account = str(request.get("accountId", ""))
    password = str(request.get("password", ""))

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
                    if not password:
                        return {"ok": False, "error": "locked"}
                    try:
                        oath.validate(oath.derive_key(password))
                    except Exception:
                        return {"ok": False, "error": "incorrect_password"}

                credential = next(
                    (item for item in oath.list_credentials() if item.id.hex() == wanted_account),
                    None,
                )
                if credential is None:
                    return {"ok": False, "error": "account_missing"}

                code = oath.calculate_code(credential)
                return {
                    "ok": True,
                    "code": code.value,
                    "validTo": code.valid_to,
                    "type": credential.oath_type.name,
                }
        except Exception as exc:
            if exc.__class__.__name__ == "ApplicationNotAvailableError":
                return {"ok": False, "error": "oath_unavailable"}
            if exc.__class__.__name__ == "TimeoutError":
                return {"ok": False, "error": "touch_timeout"}
            return {"ok": False, "error": "device_error"}

    return {"ok": False, "error": "key_disconnected"}


def clear_clipboard(request: dict[str, Any]) -> dict[str, Any]:
    expected = str(request.get("expected", ""))
    if not expected:
        return {"ok": True, "cleared": False}

    try:
        current = subprocess.run(
            ["wl-paste", "--no-newline"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"ok": False, "error": "clipboard_unavailable"}

    if current.returncode != 0 or current.stdout.decode("utf-8", errors="replace") != expected:
        return {"ok": True, "cleared": False}

    try:
        cleared = subprocess.run(
            ["wl-copy", "--clear"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"ok": False, "error": "clipboard_unavailable"}
    return {"ok": True, "cleared": cleared.returncode == 0}


def watch_devices() -> None:
    (
        _list_all_devices,
        scan_devices,
        _transport,
        usb_interface,
        _connection_type,
        _capability,
        _oath_type,
        _oath_session,
    ) = import_ykman()

    previous: tuple[tuple[tuple[int, int], ...], int] | None = None
    while True:
        pids, state = scan_devices()
        devices = []
        signature = []
        for pid, count in pids.items():
            if pid.usb_interfaces & usb_interface.CCID:
                signature.append((int(pid), int(count)))
                devices.append(
                    {
                        "productId": int(pid),
                        "model": pid.yubikey_type.value,
                        "count": int(count),
                    }
                )

        current = (tuple(sorted(signature)), int(state))
        if current != previous:
            devices.sort(key=lambda item: (item["model"], item["productId"]))
            emit({"ok": True, "devices": devices, "state": int(state)})
            previous = current
        time.sleep(0.75)


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "watch":
        try:
            watch_devices()
        except RuntimeError as exc:
            if str(exc) == "missing_dependency":
                emit({"ok": False, "error": "missing_dependency"})
                return 2
            raise
        except Exception:
            emit({"ok": False, "error": "device_detection_failed"})
            return 1

    try:
        request = read_request()
        if command == "list":
            response = list_accounts(request)
        elif command == "code":
            response = generate_code(request)
        elif command == "clear":
            response = clear_clipboard(request)
        else:
            response = {"ok": False, "error": "unknown_command"}
    except RuntimeError as exc:
        response = {"ok": False, "error": str(exc)}
    except Exception:
        response = {"ok": False, "error": "device_error"}

    emit(response)
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
