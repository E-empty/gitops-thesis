from __future__ import annotations

import csv
import io
import math
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from analysis.analyze_results import build_summary_rows, describe, iter_csv_rows, main


EXPERIMENT_FIELDS = [
    "tool",
    "test",
    "iteration",
    "start_time",
    "detection_time",
    "recovery_time",
    "total_seconds",
    "status",
]
RESOURCE_FIELDS = [
    "tool",
    "phase",
    "iteration",
    "timestamp",
    "namespace",
    "pod",
    "cpu_raw",
    "memory_raw",
    "cpu_millicores",
    "memory_mib",
    "status",
]


def write_csv(
    root: Path,
    name: str,
    fieldnames: list[str],
    rows: list[dict[str, str]],
) -> Path:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return path


def experiment_row(
    *,
    tool: str = "argocd",
    iteration: str = "1",
    start: str = "2026-01-01T00:00:00Z",
    detection: str = "2026-01-01T00:00:04Z",
    recovery: str = "2026-01-01T00:00:10Z",
    total: str = "10",
    status: str = "success",
) -> dict[str, str]:
    return {
        "tool": tool,
        "test": "scale_drift",
        "iteration": iteration,
        "start_time": start,
        "detection_time": detection,
        "recovery_time": recovery,
        "total_seconds": total,
        "status": status,
    }


def resource_row(
    *,
    tool: str = "argocd",
    iteration: str = "1",
    timestamp: str = "2026-01-01T00:00:00Z",
    pod: str = "controller-0",
    cpu: str = "10",
    memory: str = "100",
    status: str = "success",
) -> dict[str, str]:
    return {
        "tool": tool,
        "phase": "idle",
        "iteration": iteration,
        "timestamp": timestamp,
        "namespace": "argocd" if tool == "argocd" else "flux-system",
        "pod": pod,
        "cpu_raw": f"{cpu}m",
        "memory_raw": f"{memory}Mi",
        "cpu_millicores": cpu,
        "memory_mib": memory,
        "status": status,
    }


class AnalyzeResultsTests(unittest.TestCase):
    def test_describe_uses_sample_standard_deviation(self) -> None:
        result = describe([1.0, 2.0, 3.0])

        self.assertEqual(result.count, 3)
        self.assertEqual(result.mean, 2.0)
        self.assertEqual(result.median, 2.0)
        self.assertEqual(result.minimum, 1.0)
        self.assertEqual(result.maximum, 3.0)
        self.assertEqual(result.standard_deviation, 1.0)

    def test_describe_rejects_non_finite_and_negative_values(self) -> None:
        for value in (-1.0, math.nan, math.inf, -math.inf):
            with self.subTest(value=value), self.assertRaises(ValueError):
                describe([value])

    def test_build_summary_calculates_detection_recovery_and_total_for_both_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            rows = [
                experiment_row(),
                experiment_row(
                    iteration="2",
                    detection="2026-01-01T00:00:06Z",
                    recovery="2026-01-01T00:00:30Z",
                    total="30.002",
                ),
                experiment_row(iteration="3", status="recovery_timeout"),
                experiment_row(
                    tool="fluxcd",
                    start="2026-01-01T01:00:00+01:00",
                    detection="2026-01-01T01:00:02+01:00",
                    recovery="2026-01-01T01:00:05+01:00",
                    total="5",
                ),
            ]
            write_csv(root, "experiments.csv", EXPERIMENT_FIELDS, rows)

            summary = build_summary_rows(root)

        by_key = {(row["tool"], row["metric"]): row for row in summary}
        self.assertEqual(len(summary), 6)
        self.assertEqual(by_key[("argocd", "detection_seconds")]["count"], 2)
        self.assertEqual(by_key[("argocd", "detection_seconds")]["mean"], "5.000000")
        self.assertEqual(by_key[("argocd", "recovery_seconds")]["mean"], "15.000000")
        self.assertEqual(by_key[("argocd", "total_seconds")]["mean"], "20.001000")
        self.assertEqual(by_key[("fluxcd", "detection_seconds")]["mean"], "2.000000")
        self.assertEqual(by_key[("fluxcd", "recovery_seconds")]["mean"], "3.000000")
        self.assertEqual(by_key[("fluxcd", "total_seconds")]["mean"], "5.000000")

    def test_invalid_experiment_numbers_timestamps_and_order_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            rows = [
                experiment_row(),
                experiment_row(iteration="2", total="nan"),
                experiment_row(iteration="3", total="inf"),
                experiment_row(iteration="4", total="-1"),
                experiment_row(iteration="5", start="not-a-timestamp"),
                experiment_row(iteration="6", start="2026-01-01T00:00:00"),
                experiment_row(iteration="7", detection="2025-12-31T23:59:59Z"),
                experiment_row(
                    iteration="8",
                    detection="2026-01-01T00:00:11Z",
                    recovery="2026-01-01T00:00:10Z",
                ),
            ]
            write_csv(root, "invalid.csv", EXPERIMENT_FIELDS, rows)

            summary = build_summary_rows(root)

        self.assertEqual(len(summary), 3)
        self.assertTrue(all(row["count"] == 1 for row in summary))

    def test_resource_usage_is_totalled_per_sample_before_statistics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            rows = [
                resource_row(pod="argocd-a", cpu="10", memory="100"),
                resource_row(pod="argocd-b", cpu="20", memory="200"),
                resource_row(
                    iteration="2",
                    timestamp="2026-01-01T00:00:05Z",
                    pod="argocd-a",
                    cpu="40",
                    memory="100",
                ),
                resource_row(
                    iteration="2",
                    timestamp="2026-01-01T00:00:05Z",
                    pod="argocd-b",
                    cpu="10",
                    memory="100",
                ),
                # One malformed pod invalidates the complete sample rather than
                # silently undercounting the controller footprint.
                resource_row(
                    iteration="3",
                    timestamp="2026-01-01T00:00:10Z",
                    pod="argocd-a",
                ),
                resource_row(
                    iteration="3",
                    timestamp="2026-01-01T00:00:10Z",
                    pod="argocd-b",
                    memory="nan",
                ),
                resource_row(
                    iteration="3",
                    timestamp="2026-01-01T00:00:10Z",
                    pod="argocd-c",
                ),
                resource_row(
                    iteration="4",
                    timestamp="2026-01-01T00:00:15Z",
                    cpu="inf",
                ),
                resource_row(
                    iteration="5",
                    timestamp="2026-01-01T00:00:20Z",
                    memory="-1",
                ),
                resource_row(
                    tool="fluxcd",
                    pod="source-controller",
                    cpu="5",
                    memory="50",
                ),
                resource_row(
                    tool="fluxcd",
                    pod="helm-controller",
                    cpu="10",
                    memory="100",
                ),
            ]
            write_csv(root, "resources.csv", RESOURCE_FIELDS, rows)

            summary = build_summary_rows(root)

        by_key = {(row["tool"], row["metric"]): row for row in summary}
        self.assertEqual(len(summary), 4)
        self.assertEqual(by_key[("argocd", "cpu_millicores_total")]["count"], 2)
        self.assertEqual(by_key[("argocd", "cpu_millicores_total")]["mean"], "40.000000")
        self.assertEqual(by_key[("argocd", "memory_mib_total")]["mean"], "250.000000")
        self.assertEqual(by_key[("fluxcd", "cpu_millicores_total")]["mean"], "15.000000")
        self.assertEqual(by_key[("fluxcd", "memory_mib_total")]["mean"], "150.000000")

    def test_foreign_csv_schema_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_csv(root, "foreign.csv", ["name", "value"], [{"name": "x", "value": "1"}])

            self.assertEqual(build_summary_rows(root), [])

    def test_csv_discovery_error_is_reported_without_escaping(self) -> None:
        stderr = io.StringIO()
        with patch.object(Path, "rglob", side_effect=OSError("access denied")):
            with redirect_stderr(stderr):
                rows = list(iter_csv_rows(Path("unreadable")))

        self.assertEqual(rows, [])
        self.assertIn("access denied", stderr.getvalue())

    def test_cli_writes_summary_and_reports_missing_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            input_dir = root / "input"
            output_dir = root / "output"
            write_csv(input_dir, "experiment.csv", EXPERIMENT_FIELDS, [experiment_row()])

            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                result = main(["--input-dir", str(input_dir), "--output-dir", str(output_dir)])
                missing_result = main(
                    ["--input-dir", str(root / "missing"), "--output-dir", str(output_dir)]
                )

            with (output_dir / "summary.csv").open(encoding="utf-8", newline="") as handle:
                output_rows = list(csv.DictReader(handle))

        self.assertEqual(result, 0)
        self.assertEqual(missing_result, 2)
        self.assertEqual(len(output_rows), 3)
        self.assertEqual(
            {row["metric"] for row in output_rows},
            {"detection_seconds", "recovery_seconds", "total_seconds"},
        )


if __name__ == "__main__":
    unittest.main()
