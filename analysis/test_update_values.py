from __future__ import annotations

import unittest

from experiments.lib.update_values import get_value, resolve_path, set_value


VALUES = """\
services:
  gateway:
    name: gateway-service
    image:
      tag: "1.0.0"
    env:
      APP_VERSION: "1.0.0"
"""


class UpdateValuesTests(unittest.TestCase):
    def test_service_can_be_selected_by_runtime_name(self) -> None:
        lines = VALUES.splitlines(keepends=True)
        path = resolve_path(lines, "gateway-service", "image.tag")

        self.assertEqual(path, ("services", "gateway", "image", "tag"))
        self.assertEqual(get_value(lines, path), "1.0.0")

    def test_set_changes_only_the_requested_existing_scalar(self) -> None:
        lines = VALUES.splitlines(keepends=True)
        path = resolve_path(lines, "gateway", "env.APP_VERSION")

        set_value(lines, path, "1.1.0")

        self.assertEqual(get_value(lines, path), "1.1.0")
        self.assertIn('tag: "1.0.0"', "".join(lines))

    def test_hash_inside_a_quoted_value_is_not_treated_as_a_comment(self) -> None:
        lines = VALUES.splitlines(keepends=True)
        path = resolve_path(lines, "gateway", "env.APP_VERSION")

        set_value(lines, path, 'release #1 "candidate"')

        self.assertEqual(get_value(lines, path), 'release #1 "candidate"')

    def test_missing_scalar_fails_closed(self) -> None:
        lines = VALUES.splitlines(keepends=True)

        with self.assertRaisesRegex(ValueError, "scalar path not found"):
            get_value(lines, ("services", "gateway", "env", "MISSING"))

    def test_duplicate_service_scalar_is_rejected_as_ambiguous(self) -> None:
        lines = (
            VALUES
            + "  gateway:\n"
            + "    name: gateway-service\n"
            + "    image:\n"
            + '      tag: "duplicate"\n'
        ).splitlines(keepends=True)

        with self.assertRaisesRegex(ValueError, "duplicate YAML path"):
            resolve_path(lines, "gateway", "image.tag")


if __name__ == "__main__":
    unittest.main()
