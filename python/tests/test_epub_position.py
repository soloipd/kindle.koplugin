import json
import os
import sys
import tempfile
import unittest
import zipfile
from unittest import mock


PYTHON_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PYTHON_DIR not in sys.path:
    sys.path.insert(0, PYTHON_DIR)

from epub_position import (
    PositionTranslationError, translate_native_position,
    translate_native_positions, translate_xpointer)


CONTAINER = b'''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''
OPF = b'''<package xmlns="http://www.idpf.org/2007/opf">
  <manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="one"/></spine>
</package>'''
XHTML = b'''<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p data-kfx-eid="1139" data-kfx-pid="27115">Hello <em>brave</em> world</p>
</body></html>'''


class EpubPositionTests(unittest.TestCase):
    def make_epub(self):
        handle, path = tempfile.mkstemp(suffix=".epub")
        os.close(handle)
        with zipfile.ZipFile(path, "w") as epub:
            epub.writestr("META-INF/container.xml", CONTAINER)
            epub.writestr("OEBPS/content.opf", OPF)
            epub.writestr("OEBPS/one.xhtml", XHTML)
            epub.writestr("OEBPS/kindle-position-map.json", json.dumps({"version": 1}))
        self.addCleanup(os.remove, path)
        return path

    def test_translates_nested_text_to_native_eid_offset_and_pid(self):
        result = translate_xpointer(
            self.make_epub(),
            "/body/DocFragment/body/p/em/text().3",
        )
        self.assertEqual(1139, result["eid"])
        self.assertEqual(9, result["eid_offset"])
        self.assertEqual(27124, result["pid"])
        self.assertEqual("AXMEAAAJAAAA", result["long"])

    def test_translates_tail_text_from_start_of_kfx_element(self):
        result = translate_xpointer(
            self.make_epub(),
            "/body/DocFragment/body/p/text()[2].2",
        )
        self.assertEqual(13, result["eid_offset"])

    def test_rejects_out_of_range_text_offsets(self):
        with self.assertRaises(PositionTranslationError):
            translate_xpointer(
                self.make_epub(),
                "/body/DocFragment/body/p/em/text().99",
            )

    def test_round_trips_native_position_to_nested_text_xpointer(self):
        native = translate_xpointer(
            self.make_epub(), "/body/DocFragment/body/p/em/text().3")
        restored = translate_native_position(self.make_epub(), native["long"])
        self.assertEqual(native["long"], restored["long"])
        self.assertEqual(native["pid"], restored["pid"])
        self.assertEqual(
            "/body/DocFragment/body/p/em/text().3", restored["xpointer"])

    def test_round_trips_native_position_to_parent_tail_text(self):
        native = translate_xpointer(
            self.make_epub(), "/body/DocFragment/body/p/text()[2].2")
        restored = translate_native_position(self.make_epub(), native["long"])
        self.assertEqual(
            "/body/DocFragment/body/p/text()[2].2", restored["xpointer"])

    def test_reverse_batch_opens_and_parses_epub_once(self):
        epub_path = self.make_epub()
        positions = [
            translate_xpointer(
                epub_path, "/body/DocFragment/body/p/em/text().3")["long"],
            translate_xpointer(
                epub_path, "/body/DocFragment/body/p/text()[2].2")["long"],
        ]
        real_zip_file = zipfile.ZipFile
        with mock.patch(
                "epub_position.zipfile.ZipFile",
                wraps=real_zip_file) as zip_file:
            restored = translate_native_positions(epub_path, positions)
        self.assertEqual(1, zip_file.call_count)
        self.assertEqual(
            "/body/DocFragment/body/p/em/text().3",
            restored[0]["xpointer"],
        )
        self.assertEqual(
            "/body/DocFragment/body/p/text()[2].2",
            restored[1]["xpointer"],
        )


if __name__ == "__main__":
    unittest.main()
