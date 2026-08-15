import json


__license__ = "GPL v3"


POSITION_MAP_VERSION = 1
POSITION_MAP_FILEPATH = "/kindle-position-map.json"
KFX_EID_ATTRIBUTE = "data-kfx-eid"
KFX_PID_ATTRIBUTE = "data-kfx-pid"


def _plain_value(value):
    if isinstance(value, int):
        return int(value)
    if value is None:
        return None
    return str(value)


def build_position_map(chunks, asin=""):
    """Build a text-free KFX coordinate map from ContentChunk records."""
    entries = []
    bases_by_eid = {}

    for chunk in chunks:
        eid = _plain_value(chunk.eid)
        pid = int(chunk.pid)
        eid_offset = int(chunk.eid_offset)
        length = int(chunk.length)
        base_pid = pid - eid_offset

        entries.append({
            "eid": eid,
            "eid_offset": eid_offset,
            "length": length,
            "pid": pid,
            "section": _plain_value(chunk.section_name),
        })
        bases_by_eid.setdefault(eid, set()).add(base_pid)

    unique_bases = {
        eid: next(iter(bases))
        for eid, bases in bases_by_eid.items()
        if len(bases) == 1
    }

    return {
        "version": POSITION_MAP_VERSION,
        "asin": str(asin or ""),
        "coordinate_unit": "kfx-unicode-character",
        "entries": entries,
    }, unique_bases


def serialize_position_map(position_map):
    return json.dumps(
        position_map,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def tag_position_element(elem, eid, unique_bases):
    plain_eid = _plain_value(eid)
    elem.set(KFX_EID_ATTRIBUTE, str(plain_eid))
    if plain_eid in unique_bases:
        elem.set(KFX_PID_ATTRIBUTE, str(unique_bases[plain_eid]))
