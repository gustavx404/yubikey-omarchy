import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from iconpacks import IconPackError, _safe_svg, clear_aegis_pack, import_aegis_pack, load_aegis_pack


PACK_ID = "c553f06f-2a17-46ca-87f5-56af90dd0500"
SAFE_SVG = (
    b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 2">'
    b'<path d="M0 0h2v2H0z" fill="#123456"/></svg>'
)


class AegisIconPackTests(unittest.TestCase):
    def create_archive(self, archive_path, icon_path="services/Example.svg", image=SAFE_SVG, issuer=None):
        manifest = {
            "uuid": PACK_ID,
            "name": "Test pack",
            "version": 1,
            "icons": [{"filename": icon_path, "category": "Services", "issuer": issuer or ["Example", "example.test"]}],
        }
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("pack.json", json.dumps(manifest))
            archive.writestr("services/Example.svg", image)
            archive.writestr("unused.txt", "ignored")

    def test_imports_only_referenced_assets_and_loads_pack(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "pack.zip"
            storage_path = root / "icons"
            storage_path.mkdir()
            self.create_archive(archive_path)

            result = import_aegis_pack(str(archive_path), str(storage_path))
            loaded = load_aegis_pack(str(storage_path))

            self.assertEqual(result, {"ok": True, "name": "Test pack", "count": 1})
            self.assertTrue(loaded["ok"])
            self.assertEqual(loaded["pack"]["name"], "Test pack")
            self.assertEqual(loaded["pack"]["icons"][0]["issuer"], ["example", "example.test"])
            relative_file = loaded["pack"]["icons"][0]["file"]
            self.assertEqual((storage_path / relative_file).read_bytes(), SAFE_SVG)
            self.assertEqual(list(storage_path.rglob("unused.txt")), [])

    def test_rejects_archive_path_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "pack.zip"
            storage_path = root / "icons"
            storage_path.mkdir()
            self.create_archive(archive_path, icon_path="../outside.svg")

            with self.assertRaises(IconPackError):
                import_aegis_pack(str(archive_path), str(storage_path))
            self.assertEqual(list(root.glob("outside.svg")), [])

    def test_rejects_active_svg_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "pack.zip"
            storage_path = root / "icons"
            storage_path.mkdir()
            self.create_archive(archive_path, image=b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')

            with self.assertRaises(IconPackError):
                import_aegis_pack(str(archive_path), str(storage_path))

    def test_allows_internal_svg_references_and_blocks_external_references(self):
        _safe_svg(b'<svg xmlns="http://www.w3.org/2000/svg"><path style="fill:url(#paint)"/></svg>')
        with self.assertRaises(IconPackError):
            _safe_svg(b'<svg xmlns="http://www.w3.org/2000/svg"><path style="fill:url(https://example.test/x)"/></svg>')

    def test_clear_removes_active_mapping_and_imported_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "pack.zip"
            storage_path = root / "icons"
            storage_path.mkdir()
            self.create_archive(archive_path)
            import_aegis_pack(str(archive_path), str(storage_path))
            active_file = storage_path / "active.json"
            self.assertTrue(active_file.exists())

            self.assertEqual(clear_aegis_pack(str(storage_path)), {"ok": True})
            self.assertFalse(active_file.exists())
            self.assertEqual(list(storage_path.rglob("*.svg")), [])
            self.assertEqual(load_aegis_pack(str(storage_path)), {"ok": True, "pack": None})


if __name__ == "__main__":
    unittest.main()
