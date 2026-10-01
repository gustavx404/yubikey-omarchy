"""Safe importer for Aegis-compatible icon packs."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
import unicodedata
import uuid
import xml.etree.ElementTree as ElementTree
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 4096
MAX_TOTAL_UNPACKED_BYTES = 128 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_ICON_BYTES = 4 * 1024 * 1024
MAX_IMAGE_DIMENSION = 2048
MAX_ICONS = 2048
MAX_ISSUERS_PER_ICON = 32
MAX_TEXT_LENGTH = 128
ACTIVE_PACK_NAME = "active.json"
SUPPORTED_EXTENSIONS = {".svg", ".png", ".jpg"}
OUTPUT_FILE = re.compile(r"^[a-f0-9-]{36}/[1-9][0-9]{0,8}/[a-f0-9]{64}\.(?:svg|png|jpg)$")


class IconPackError(ValueError):
    """The selected archive is not a supported, safe icon pack."""


def _clean_text(value: Any, limit: int = MAX_TEXT_LENGTH) -> str:
    if not isinstance(value, str):
        raise IconPackError("invalid_icon_pack")
    cleaned = "".join(
        char if not unicodedata.category(char).startswith("C") else " "
        for char in value
    )
    cleaned = " ".join(cleaned.split())[:limit]
    if not cleaned:
        raise IconPackError("invalid_icon_pack")
    return cleaned


def _safe_archive_path(value: Any) -> str:
    if not isinstance(value, str) or not value or len(value) > 512 or "\\" in value or "\0" in value:
        raise IconPackError("invalid_icon_pack")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise IconPackError("invalid_icon_pack")
    return path.as_posix()


def _json_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise IconPackError("invalid_icon_pack")
        result[key] = value
    return result


def _safe_svg(data: bytes) -> None:
    try:
        source = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise IconPackError("invalid_icon_pack") from exc
    if re.search(
        r"<!\s*(?:DOCTYPE|ENTITY)|<\s*(?:script|foreignObject)\b|@import|javascript:|xml-stylesheet",
        source,
        flags=re.IGNORECASE,
    ):
        raise IconPackError("invalid_icon_pack")
    url_starts = re.findall(r"url\s*\(", source, flags=re.IGNORECASE)
    urls = re.findall(r"url\s*\(\s*([^)]*)\)", source, flags=re.IGNORECASE)
    if len(url_starts) != len(urls) or any(not value.strip().strip("\"'").startswith("#") for value in urls):
        raise IconPackError("invalid_icon_pack")
    try:
        root = ElementTree.fromstring(source)
    except ElementTree.ParseError as exc:
        raise IconPackError("invalid_icon_pack") from exc
    if root.tag.rsplit("}", 1)[-1].lower() != "svg":
        raise IconPackError("invalid_icon_pack")
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1].lower() in {"script", "foreignobject"}:
            raise IconPackError("invalid_icon_pack")
        for key, value in element.attrib.items():
            local_key = key.rsplit("}", 1)[-1].lower()
            if local_key.startswith("on"):
                raise IconPackError("invalid_icon_pack")
            if local_key == "href" and value and not value.startswith("#"):
                raise IconPackError("invalid_icon_pack")


def _validate_image(filename: str, data: bytes) -> str:
    extension = Path(filename).suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS or not data or len(data) > MAX_ICON_BYTES:
        raise IconPackError("invalid_icon_pack")
    if extension == ".png":
        if len(data) < 24 or not data.startswith(b"\x89PNG\r\n\x1a\n") or data[12:16] != b"IHDR":
            raise IconPackError("invalid_icon_pack")
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        if not width or not height or width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
            raise IconPackError("invalid_icon_pack")
    if extension == ".jpg":
        width, height = _jpeg_dimensions(data)
        if width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
            raise IconPackError("invalid_icon_pack")
    if extension == ".svg":
        _safe_svg(data)
    return extension


def _jpeg_dimensions(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\xff\xd8"):
        raise IconPackError("invalid_icon_pack")
    offset = 2
    start_of_frame = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            raise IconPackError("invalid_icon_pack")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        if marker in {0xD8, 0xD9, 0x01} or 0xD0 <= marker <= 0xD7:
            continue
        if marker == 0xDA or offset + 2 > len(data):
            break
        segment_length = int.from_bytes(data[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(data):
            raise IconPackError("invalid_icon_pack")
        if marker in start_of_frame:
            if segment_length < 7:
                raise IconPackError("invalid_icon_pack")
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
            if not width or not height:
                raise IconPackError("invalid_icon_pack")
            return width, height
        offset += segment_length
    raise IconPackError("invalid_icon_pack")


def _ensure_directory(path: Path) -> None:
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        if path.is_symlink() or not path.is_dir():
            raise IconPackError("invalid_icon_pack")


def _atomic_write(path: Path, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".icon-pack-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _remove_pack_assets(root: Path, pack: dict[str, Any], keep: set[str] | None = None) -> None:
    keep = keep or set()
    directories: set[Path] = set()
    for icon in pack.get("icons", []):
        filename = icon.get("file")
        if not isinstance(filename, str) or not OUTPUT_FILE.fullmatch(filename) or filename in keep:
            continue
        asset = root / filename
        if asset.is_symlink() or not asset.is_file():
            continue
        try:
            asset.unlink()
            directories.add(asset.parent)
            directories.add(asset.parent.parent)
        except OSError:
            continue
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass


def _parse_manifest(data: bytes) -> dict[str, Any]:
    if not data or len(data) > MAX_MANIFEST_BYTES:
        raise IconPackError("invalid_icon_pack")
    try:
        manifest = json.loads(data, object_pairs_hook=_json_without_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise IconPackError("invalid_icon_pack") from exc
    if not isinstance(manifest, dict):
        raise IconPackError("invalid_icon_pack")

    try:
        pack_id = str(uuid.UUID(manifest["uuid"]))
        version = manifest["version"]
        if type(version) is not int or version < 1 or version > 999_999_999:
            raise IconPackError("invalid_icon_pack")
        name = _clean_text(manifest["name"])
        raw_icons = manifest["icons"]
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        raise IconPackError("invalid_icon_pack") from exc
    if not isinstance(raw_icons, list) or not raw_icons or len(raw_icons) > MAX_ICONS:
        raise IconPackError("invalid_icon_pack")

    icons: list[dict[str, Any]] = []
    for item in raw_icons:
        if not isinstance(item, dict):
            raise IconPackError("invalid_icon_pack")
        try:
            filename = _safe_archive_path(item["filename"])
            aliases = item["issuer"]
        except KeyError as exc:
            raise IconPackError("invalid_icon_pack") from exc
        if not isinstance(aliases, list) or not aliases or len(aliases) > MAX_ISSUERS_PER_ICON:
            raise IconPackError("invalid_icon_pack")
        clean_aliases = list(dict.fromkeys(_clean_text(alias).casefold() for alias in aliases))
        label = item.get("name", "")
        if label:
            _clean_text(label)
        icons.append({"archivePath": filename, "issuer": clean_aliases})

    return {"uuid": pack_id, "version": version, "name": name, "icons": icons}


def import_aegis_pack(archive_path: str, storage_path: str) -> dict[str, Any]:
    root = Path(storage_path)
    if root.is_symlink() or not root.is_dir():
        raise IconPackError("invalid_icon_pack")
    try:
        previous_pack = load_aegis_pack(storage_path).get("pack")
    except IconPackError:
        previous_pack = None

    archive = Path(archive_path)
    try:
        info = archive.stat()
    except OSError as exc:
        raise IconPackError("invalid_icon_pack") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_size < 1 or info.st_size > MAX_ARCHIVE_BYTES:
        raise IconPackError("invalid_icon_pack")

    try:
        with zipfile.ZipFile(archive) as package:
            members = package.infolist()
            if len(members) > MAX_ARCHIVE_ENTRIES or sum(item.file_size for item in members) > MAX_TOTAL_UNPACKED_BYTES:
                raise IconPackError("invalid_icon_pack")
            names: dict[str, zipfile.ZipInfo] = {}
            for member in members:
                member_name = _safe_archive_path(member.filename.rstrip("/")) if member.filename.rstrip("/") else ""
                if not member_name:
                    continue
                if member_name in names or stat.S_ISLNK(member.external_attr >> 16):
                    raise IconPackError("invalid_icon_pack")
                names[member_name] = member
            manifest_member = names.get("pack.json")
            if manifest_member is None or manifest_member.file_size > MAX_MANIFEST_BYTES:
                raise IconPackError("invalid_icon_pack")
            manifest = _parse_manifest(package.read(manifest_member))
            pack_directory = root / manifest["uuid"] / str(manifest["version"])
            _ensure_directory(root / manifest["uuid"])
            _ensure_directory(pack_directory)

            total_size = 0
            public_icons: list[dict[str, Any]] = []
            for icon in manifest["icons"]:
                member = names.get(icon["archivePath"])
                if member is None or member.file_size > MAX_ICON_BYTES:
                    raise IconPackError("invalid_icon_pack")
                total_size += member.file_size
                if total_size > MAX_TOTAL_UNPACKED_BYTES:
                    raise IconPackError("invalid_icon_pack")
                data = package.read(member)
                extension = _validate_image(icon["archivePath"], data)
                digest = hashlib.sha256(icon["archivePath"].encode("utf-8")).hexdigest()
                relative_path = f"{manifest['uuid']}/{manifest['version']}/{digest}{extension}"
                destination = root / relative_path
                if destination.parent != pack_directory:
                    raise IconPackError("invalid_icon_pack")
                _atomic_write(destination, data, 0o644)
                public_icons.append({"issuer": icon["issuer"], "file": relative_path})

            result = {
                "uuid": manifest["uuid"],
                "version": manifest["version"],
                "name": manifest["name"],
                "icons": public_icons,
            }
            active_bytes = json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
            if len(active_bytes) > MAX_MANIFEST_BYTES:
                raise IconPackError("invalid_icon_pack")
            _atomic_write(root / ACTIVE_PACK_NAME, active_bytes, 0o600)
            if previous_pack:
                _remove_pack_assets(root, previous_pack, {icon["file"] for icon in public_icons})
            return {"ok": True, "name": manifest["name"], "count": len(public_icons)}
    except (OSError, zipfile.BadZipFile, RuntimeError, KeyError, TypeError, OverflowError) as exc:
        raise IconPackError("invalid_icon_pack") from exc


def load_aegis_pack(storage_path: str) -> dict[str, Any]:
    root = Path(storage_path)
    try:
        active_path = root / ACTIVE_PACK_NAME
        if root.is_symlink() or active_path.is_symlink():
            raise IconPackError("invalid_icon_pack")
        raw = active_path.read_bytes()
        if len(raw) > MAX_MANIFEST_BYTES:
            raise IconPackError("invalid_icon_pack")
        pack = json.loads(raw, object_pairs_hook=_json_without_duplicates)
        if not isinstance(pack, dict) or set(pack) != {"uuid", "version", "name", "icons"}:
            raise IconPackError("invalid_icon_pack")
        pack_id = str(uuid.UUID(pack["uuid"]))
        version = pack["version"]
        if type(version) is not int or version < 1 or version > 999_999_999:
            raise IconPackError("invalid_icon_pack")
        name = _clean_text(pack["name"])
        icons = pack["icons"]
        if not isinstance(icons, list) or len(icons) > MAX_ICONS:
            raise IconPackError("invalid_icon_pack")
        safe_icons = []
        for icon in icons:
            if not isinstance(icon, dict) or set(icon) != {"issuer", "file"}:
                raise IconPackError("invalid_icon_pack")
            aliases = icon["issuer"]
            filename = icon["file"]
            if not isinstance(aliases, list) or not aliases or len(aliases) > MAX_ISSUERS_PER_ICON:
                raise IconPackError("invalid_icon_pack")
            if not all(isinstance(alias, str) and alias == _clean_text(alias).casefold() for alias in aliases):
                raise IconPackError("invalid_icon_pack")
            if not isinstance(filename, str) or not OUTPUT_FILE.fullmatch(filename):
                raise IconPackError("invalid_icon_pack")
            if not filename.startswith(f"{pack_id}/{version}/"):
                raise IconPackError("invalid_icon_pack")
            asset = root / filename
            pack_directory = root / pack_id / str(version)
            if (root / pack_id).is_symlink() or pack_directory.is_symlink() or asset.is_symlink() or not asset.is_file():
                raise IconPackError("invalid_icon_pack")
            safe_icons.append({"issuer": aliases, "file": filename})
        return {"ok": True, "pack": {"uuid": pack_id, "version": version, "name": name, "icons": safe_icons}}
    except FileNotFoundError:
        return {"ok": True, "pack": None}
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError, OverflowError):
        raise IconPackError("invalid_icon_pack")


def clear_aegis_pack(storage_path: str) -> dict[str, Any]:
    root = Path(storage_path)
    try:
        active = root / ACTIVE_PACK_NAME
        if root.is_symlink() or active.is_symlink():
            raise IconPackError("invalid_icon_pack")
        pack = load_aegis_pack(storage_path).get("pack")
        active.unlink(missing_ok=True)
        if pack:
            _remove_pack_assets(root, pack)
        return {"ok": True}
    except OSError as exc:
        raise IconPackError("invalid_icon_pack") from exc
