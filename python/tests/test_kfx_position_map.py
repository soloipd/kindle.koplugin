import json
import importlib.util
import os
import sys
import unittest
from collections import namedtuple

from xml.etree import ElementTree


PYTHON_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PYTHON_DIR not in sys.path:
    sys.path.insert(0, PYTHON_DIR)

MODULE_PATH = os.path.join(PYTHON_DIR, "kfxlib", "kfx_position_map.py")
SPEC = importlib.util.spec_from_file_location("kfx_position_map", MODULE_PATH)
kfx_position_map = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kfx_position_map)

build_position_map = kfx_position_map.build_position_map
serialize_position_map = kfx_position_map.serialize_position_map
tag_position_element = kfx_position_map.tag_position_element
ContentChunk = namedtuple(
    "ContentChunk",
    "pid eid eid_offset length section_name text",
    defaults=[None],
)


class KfxPositionMapTests(unittest.TestCase):
    def test_map_contains_coordinates_but_not_content_text(self):
        chunks = [
            ContentChunk(100, 7, 0, 5, "section-1", text="hello"),
            ContentChunk(105, 7, 5, 4, "section-1", text="book"),
        ]

        position_map, unique_bases = build_position_map(chunks, asin="B012345678")
        encoded = serialize_position_map(position_map)
        decoded = json.loads(encoded.decode("utf-8"))

        self.assertEqual(1, decoded["version"])
        self.assertEqual("B012345678", decoded["asin"])
        self.assertEqual(100, unique_bases[7])
        self.assertNotIn(b"hello", encoded)
        self.assertNotIn(b"book", encoded)
        self.assertEqual(
            {"eid": 7, "eid_offset": 5, "length": 4, "pid": 105, "section": "section-1"},
            decoded["entries"][1],
        )

    def test_ambiguous_eid_does_not_publish_a_misleading_base_pid(self):
        chunks = [
            ContentChunk(10, 3, 0, 1, "a", text="x"),
            ContentChunk(50, 3, 0, 1, "b", text="y"),
        ]

        _, unique_bases = build_position_map(chunks)
        elem = ElementTree.Element("span")
        tag_position_element(elem, 3, unique_bases)

        self.assertEqual("3", elem.get("data-kfx-eid"))
        self.assertIsNone(elem.get("data-kfx-pid"))

    def test_unique_eid_tags_element_with_eid_and_base_pid(self):
        chunks = [ContentChunk(42, 9, 2, 3, "section", text="abc")]
        _, unique_bases = build_position_map(chunks)
        elem = ElementTree.Element("span")

        tag_position_element(elem, 9, unique_bases)

        self.assertEqual("9", elem.get("data-kfx-eid"))
        self.assertEqual("40", elem.get("data-kfx-pid"))


if __name__ == "__main__":
    unittest.main()
