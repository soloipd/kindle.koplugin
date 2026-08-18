"""Compatibility exports for the lightweight top-level position module."""

from epub_position import (
    PositionTranslationError,
    translate_native_position,
    translate_native_positions,
    translate_pair,
    translate_xpointer,
)

__all__ = [
    "PositionTranslationError",
    "translate_native_position",
    "translate_native_positions",
    "translate_pair",
    "translate_xpointer",
]
