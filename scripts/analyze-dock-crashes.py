#!/usr/bin/env python3
"""Summarize macOS Dock .ips reports without inferring ownership of adjacent VM regions."""

import argparse
from collections import Counter
from pathlib import Path
import json


def read_report(path):
    text = path.read_text()
    decoder = json.JSONDecoder()
    first, end = decoder.raw_decode(text.lstrip())
    remainder = text.lstrip()[end:].strip()
    report = json.loads(remainder) if remainder else first
    meta = first if remainder else {}
    index = report.get("faultingThread")
    threads = report.get("threads", [])
    fault = threads[index] if isinstance(index, int) and 0 <= index < len(threads) else {}
    state = fault.get("threadState", {})
    registers = {name: value.get("value") for name, value in state.items()
                 if isinstance(value, dict) and isinstance(value.get("value"), int)}
    frames = fault.get("frames", [])
    stack = [frame.get("symbol", "") for frame in frames]
    queues = [thread.get("queue", thread.get("name", "")) for thread in threads]
    copy_fault = any(name.startswith("_platform_memmove") for name in stack)
    destination = registers.get("r13")
    first_store = (copy_fault and destination is not None
                   and registers.get("rax") == registers.get("rdi")
                   == registers.get("cr2") == destination)
    return {
        "path": str(path),
        "timestamp": meta.get("timestamp", report.get("captureTime")),
        "dock_version": meta.get("build_version"),
        "incident_id": meta.get("incident_id", report.get("incident")),
        "pid": report.get("pid"),
        "uptime": report.get("uptime"),
        "fault_queue": fault.get("queue"),
        "nvmtl_image_read": any(name == "nvmtl_vk_image_read" for name in stack),
        "lp_info_thread": "LPApp information gathering" in queues,
        "exception": report.get("exception"),
        "stack": stack,
        "registers": {name: hex(value) for name, value in registers.items()},
        # Specific to this x86_64 NVMTL image_read row-loop implementation.
        # RBX is the rows still to copy, not proof of total image height.
        "row_bytes": registers.get("r12") if copy_fault else None,
        "rows_remaining": registers.get("rbx") if copy_fault else None,
        "fault_on_first_store_of_current_row": first_store,
        "vm_region_info": report.get("vmRegionInfo"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="*", type=Path,
                        help=".ips files; defaults to the current user's Dock reports")
    parser.add_argument("--json", action="store_true", help="emit complete structured evidence")
    args = parser.parse_args()
    paths = args.reports or sorted((Path.home() / "Library/Logs/DiagnosticReports").glob("Dock-*.ips"))
    reports, errors = [], []
    for path in paths:
        try:
            reports.append(read_report(path))
        except (OSError, ValueError, TypeError, KeyError) as error:
            errors.append({"path": str(path), "error": str(error)})
    matching = [report for report in reports if report["nvmtl_image_read"]]
    summary = {
        "reports": len(reports),
        "nvmtl_image_read_reports": len(matching),
        "by_dock_version": dict(Counter(report["dock_version"] or "unknown" for report in matching)),
        "with_lp_info_thread": sum(report["lp_info_thread"] for report in matching),
        "without_lp_info_thread": sum(not report["lp_info_thread"] for report in matching),
        "first_store_faults": sum(report["fault_on_first_store_of_current_row"] for report in matching),
        "row_loop_counts": dict(Counter(f"{report['row_bytes']} bytes, {report['rows_remaining']} remaining rows"
                                        for report in matching)),
        "parse_errors": errors,
    }
    print(json.dumps({"summary": summary, "reports": reports} if args.json else summary,
                     ensure_ascii=False, indent=2))
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
