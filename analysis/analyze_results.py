#!/usr/bin/env python3
"""Aggregate raw GitOps experiment CSV files using only the standard library."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Mapping, Sequence


EXPERIMENT_COLUMNS = {
    "tool",
    "test",
    "iteration",
    "start_time",
    "detection_time",
    "recovery_time",
    "total_seconds",
    "status",
}
RESOURCE_COLUMNS = {
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
}


@dataclass(frozen=True)
class Summary:
    count: int
    mean: float
    median: float
    minimum: float
    maximum: float
    standard_deviation: float


def describe(values: Sequence[float]) -> Summary:
    """Return descriptive statistics; standard deviation is the sample SD."""
    if not values:
        raise ValueError("at least one observation is required")
    if any(not math.isfinite(value) or value < 0 for value in values):
        raise ValueError("observations must be finite and non-negative")
    return Summary(
        count=len(values),
        mean=statistics.fmean(values),
        median=statistics.median(values),
        minimum=min(values),
        maximum=max(values),
        standard_deviation=statistics.stdev(values) if len(values) > 1 else 0.0,
    )


def iter_csv_paths(input_dir: Path) -> Iterable[Path]:
    """Yield CSV paths without crashing when part of the tree is unreadable."""
    discovered: list[Path] = []
    try:
        paths = input_dir.rglob("*.csv")
        while True:
            try:
                discovered.append(next(paths))
            except StopIteration:
                break
            except OSError as exc:
                print(f"warning: stopped CSV discovery below {input_dir}: {exc}", file=sys.stderr)
                break
    except OSError as exc:
        print(f"warning: could not search {input_dir}: {exc}", file=sys.stderr)
        return

    yield from sorted(discovered)


def iter_csv_rows(input_dir: Path) -> Iterable[tuple[Path, Mapping[str, str]]]:
    for csv_path in iter_csv_paths(input_dir):
        try:
            with csv_path.open("r", encoding="utf-8", newline="") as handle:
                reader = csv.DictReader(handle)
                if not reader.fieldnames:
                    continue
                for row in reader:
                    yield csv_path, row
        except (OSError, UnicodeError, csv.Error) as exc:
            print(f"warning: skipped {csv_path}: {exc}", file=sys.stderr)


def parse_timestamp(value: str | None) -> datetime:
    """Parse a timezone-aware ISO 8601 timestamp."""
    if not value or not value.strip():
        raise ValueError("timestamp is empty")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include a UTC offset")
    return parsed


def parse_nonnegative_number(value: str | None) -> float:
    if value is None:
        raise ValueError("number is missing")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise ValueError("number must be finite and non-negative")
    return parsed


def parse_nonnegative_integer(value: str | None) -> int:
    if value is None:
        raise ValueError("integer is missing")
    parsed = int(value)
    if parsed < 0 or str(parsed) != value.strip():
        raise ValueError("integer must be canonical and non-negative")
    return parsed


def elapsed_seconds(start: datetime, end: datetime) -> float:
    value = (end - start).total_seconds()
    if not math.isfinite(value) or value < 0:
        raise ValueError("timestamps must be chronological")
    return value


def collect_experiment_durations(
    input_dir: Path,
) -> dict[tuple[str, str, str], list[float]]:
    groups: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for path, row in iter_csv_rows(input_dir):
        if set(row) != EXPERIMENT_COLUMNS:
            continue
        if row.get("status") != "success":
            continue
        tool = row.get("tool", "").strip()
        test = row.get("test", "").strip()
        if not tool or not test:
            continue
        try:
            parse_nonnegative_integer(row.get("iteration"))
            start = parse_timestamp(row.get("start_time"))
            detection = parse_timestamp(row.get("detection_time"))
            recovery = parse_timestamp(row.get("recovery_time"))
            total = parse_nonnegative_number(row.get("total_seconds"))
            durations = {
                "detection_seconds": elapsed_seconds(start, detection),
                "recovery_seconds": elapsed_seconds(detection, recovery),
                # The runner records this value from a monotonic clock. Prefer
                # it over subtracting wall-clock timestamps, which NTP can move.
                "total_seconds": total,
            }
        except (TypeError, ValueError, OverflowError) as exc:
            print(f"warning: skipped invalid successful experiment row in {path}: {exc}", file=sys.stderr)
            continue
        for metric, duration in durations.items():
            groups[(tool, test, metric)].append(duration)
    return dict(groups)


def collect_resource_usage(
    input_dir: Path,
) -> tuple[dict[tuple[str, str], list[float]], dict[tuple[str, str], list[float]]]:
    sample_totals: dict[tuple[str, str, int, datetime], list[float]] = defaultdict(
        lambda: [0.0, 0.0]
    )
    invalid_samples: set[tuple[str, str, int, datetime]] = set()

    for path, row in iter_csv_rows(input_dir):
        if set(row) != RESOURCE_COLUMNS:
            continue
        tool = row.get("tool", "").strip()
        phase = row.get("phase", "").strip()
        if not tool or not phase:
            continue
        try:
            iteration = parse_nonnegative_integer(row.get("iteration"))
            timestamp = parse_timestamp(row.get("timestamp"))
        except (TypeError, ValueError, OverflowError) as exc:
            print(f"warning: skipped resource row with invalid sample key in {path}: {exc}", file=sys.stderr)
            continue
        sample_key = (tool, phase, iteration, timestamp)
        if row.get("status") != "success" or not row.get("pod", "").strip():
            invalid_samples.add(sample_key)
            sample_totals.pop(sample_key, None)
            continue
        try:
            # Parse both values before mutating either aggregate. This prevents
            # malformed memory data from leaving behind a partial CPU sample.
            cpu = parse_nonnegative_number(row.get("cpu_millicores"))
            memory = parse_nonnegative_number(row.get("memory_mib"))
        except (TypeError, ValueError, OverflowError) as exc:
            print(f"warning: invalidated resource sample in {path}: {exc}", file=sys.stderr)
            invalid_samples.add(sample_key)
            sample_totals.pop(sample_key, None)
            continue
        if sample_key not in invalid_samples:
            sample_totals[sample_key][0] += cpu
            sample_totals[sample_key][1] += memory

    cpu_groups: dict[tuple[str, str], list[float]] = defaultdict(list)
    memory_groups: dict[tuple[str, str], list[float]] = defaultdict(list)
    for (tool, phase, _iteration, _timestamp), (cpu, memory) in sample_totals.items():
        key = (tool, phase)
        cpu_groups[key].append(cpu)
        memory_groups[key].append(memory)
    return dict(cpu_groups), dict(memory_groups)


SUMMARY_FIELDS = [
    "tool",
    "test",
    "metric",
    "count",
    "mean",
    "median",
    "minimum",
    "maximum",
    "standard_deviation",
]


def summary_row(tool: str, test: str, metric: str, values: Sequence[float]) -> dict[str, str | int]:
    result = describe(values)
    return {
        "tool": tool,
        "test": test,
        "metric": metric,
        "count": result.count,
        "mean": f"{result.mean:.6f}",
        "median": f"{result.median:.6f}",
        "minimum": f"{result.minimum:.6f}",
        "maximum": f"{result.maximum:.6f}",
        "standard_deviation": f"{result.standard_deviation:.6f}",
    }


def build_summary_rows(input_dir: Path) -> list[dict[str, str | int]]:
    rows: list[dict[str, str | int]] = []
    for (tool, test, metric), values in sorted(collect_experiment_durations(input_dir).items()):
        rows.append(summary_row(tool, test, metric, values))

    cpu_groups, memory_groups = collect_resource_usage(input_dir)
    for (tool, phase), values in sorted(cpu_groups.items()):
        rows.append(summary_row(tool, f"resource_{phase}", "cpu_millicores_total", values))
    for (tool, phase), values in sorted(memory_groups.items()):
        rows.append(summary_row(tool, f"resource_{phase}", "memory_mib_total", values))
    return rows


def write_summary(path: Path, rows: Sequence[Mapping[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def print_summary(rows: Sequence[Mapping[str, object]]) -> None:
    if not rows:
        print("No successful measurements found.")
        return
    print(
        f"{'tool':<8} {'test':<24} {'metric':<18} {'n':>5} "
        f"{'mean':>12} {'median':>12} {'min':>12} {'max':>12} {'sd':>12}"
    )
    for row in rows:
        print(
            f"{str(row['tool']):<8} {str(row['test']):<24} {str(row['metric']):<18} "
            f"{int(row['count']):>5} {float(row['mean']):>12.3f} "
            f"{float(row['median']):>12.3f} {float(row['minimum']):>12.3f} "
            f"{float(row['maximum']):>12.3f} {float(row['standard_deviation']):>12.3f}"
        )


def generate_plots(rows: Sequence[Mapping[str, object]], output_dir: Path) -> bool:
    """Generate compact comparison charts when matplotlib is installed."""
    try:
        import matplotlib.pyplot as plt  # type: ignore[import-not-found]
    except ImportError:
        print("warning: matplotlib is not installed; CSV summary was still generated", file=sys.stderr)
        return False

    metrics = sorted({str(row["metric"]) for row in rows})
    for metric in metrics:
        selected = [row for row in rows if row["metric"] == metric]
        if not selected:
            continue
        labels = [f"{row['test']}\n{row['tool']}" for row in selected]
        means = [float(row["mean"]) for row in selected]
        deviations = [float(row["standard_deviation"]) for row in selected]
        figure_width = max(7.0, len(labels) * 1.1)
        fig, ax = plt.subplots(figsize=(figure_width, 4.8))
        ax.bar(labels, means, yerr=deviations, capsize=4)
        ax.set_ylabel(metric.replace("_", " "))
        ax.set_title(f"Argo CD vs Flux CD — {metric.replace('_', ' ')}")
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout()
        fig.savefig(output_dir / f"comparison-{metric}.png", dpi=150)
        plt.close(fig)
    return True


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=Path("results"))
    parser.add_argument("--output-dir", type=Path, default=Path("analysis/output"))
    parser.add_argument(
        "--plots",
        action="store_true",
        help="generate PNG comparison charts when matplotlib is available",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.input_dir.is_dir():
        print(f"error: input directory does not exist: {args.input_dir}", file=sys.stderr)
        return 2
    rows = build_summary_rows(args.input_dir)
    output_path = args.output_dir / "summary.csv"
    write_summary(output_path, rows)
    print_summary(rows)
    print(f"\nSummary written to {output_path}")
    if args.plots:
        generate_plots(rows, args.output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
