#!/usr/bin/env python3
"""Report public Swift declarations with no apparent textual in-repository references.

This is a conservative candidate finder, not a dead-code proof. It intentionally
uses only the Python standard library and deterministic sorting/JSON output.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SWIFT_SUFFIX = ".swift"
DEFAULT_ROOTS = ("Sources", "App")
DEFAULT_EXCLUDES = {".git", ".build", "DerivedData", "Packages", "Pods", "Carthage"}

DECLARATION_RE = re.compile(
    r"\b(?P<access>public|open)\b"
    r"(?:\s+(?:final|static|class|mutating|nonmutating|override|indirect|isolated|"
    r"prefix|postfix|convenience|required|weak|lazy|async|throws|rethrows))*"
    r"\s+(?P<kind>class|struct|enum|protocol|actor|typealias|init|deinit|func|"
    r"var|let|subscript)\b\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)?"
)
TOKEN_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
PROTOCOL_RE = re.compile(r"\bprotocol\s+[A-Za-z_][A-Za-z0-9_]*\b[^\{]*\{")


@dataclass(frozen=True)
class Declaration:
    path: str
    line: int
    access: str
    kind: str
    name: str
    rationale: str

    def as_json(self) -> dict[str, object]:
        return {
            "path": self.path,
            "line": self.line,
            "access": self.access,
            "kind": self.kind,
            "name": self.name,
            "rationale": self.rationale,
        }


def strip_comments_and_strings(source: str) -> str:
    """Blank comments/strings while preserving newlines and token positions."""
    out: list[str] = []
    i = 0
    state = "code"
    block_depth = 0
    while i < len(source):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""
        if state == "code":
            if c == "/" and n == "/":
                out.extend("  ")
                i += 2
                state = "line_comment"
            elif c == "/" and n == "*":
                out.extend("  ")
                i += 2
                state = "block_comment"
                block_depth = 1
            elif c == '"':
                out.append(" ")
                i += 1
                state = "string"
            else:
                out.append(c)
                i += 1
        elif state == "line_comment":
            if c == "\n":
                out.append("\n")
                i += 1
                state = "code"
            else:
                out.append(" ")
                i += 1
        elif state == "block_comment":
            if c == "/" and n == "*":
                out.extend("  ")
                i += 2
                block_depth += 1
            elif c == "*" and n == "/":
                out.extend("  ")
                i += 2
                block_depth -= 1
                if block_depth == 0:
                    state = "code"
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        else:  # string (including interpolation contents, conservatively blanked)
            if c == "\\" and n:
                out.extend("  ")
                i += 2
            elif c == '"':
                out.append(" ")
                i += 1
                state = "code"
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
    return "".join(out)


def swift_files(roots: Iterable[Path], excludes: set[str]) -> list[Path]:
    files: set[Path] = set()
    for root in roots:
        if root.is_file() and root.suffix == SWIFT_SUFFIX:
            files.add(root)
        elif root.is_dir():
            for path in root.rglob(f"*{SWIFT_SUFFIX}"):
                if not any(part in excludes for part in path.parts):
                    files.add(path)
    return sorted(files, key=lambda p: p.as_posix())


def protocol_body_lines(cleaned: str) -> set[int]:
    """Return lines inside protocol bodies, excluding requirements from candidates."""
    excluded: set[int] = set()
    for match in PROTOCOL_RE.finditer(cleaned):
        depth = 0
        started = False
        for index in range(match.start(), len(cleaned)):
            char = cleaned[index]
            if char == "{":
                depth += 1
                started = True
            elif char == "}":
                depth -= 1
                if started and depth == 0:
                    break
            if started and depth > 0:
                excluded.add(cleaned.count("\n", 0, index) + 1)
    return excluded


def scan(paths: list[Path], repo_root: Path) -> tuple[list[Declaration], dict[str, int]]:
    contents: dict[Path, str] = {}
    cleaned: dict[Path, str] = {}
    for path in paths:
        text = path.read_text(encoding="utf-8")
        contents[path] = text
        cleaned[path] = strip_comments_and_strings(text)

    tokens: dict[str, int] = {}
    for text in cleaned.values():
        for token in TOKEN_RE.findall(text):
            tokens[token] = tokens.get(token, 0) + 1

    declarations: list[Declaration] = []
    declaration_counts: dict[str, int] = {}
    for path in paths:
        text = cleaned[path]
        protocol_lines = protocol_body_lines(text)
        for line_number, line in enumerate(text.splitlines(), 1):
            for match in DECLARATION_RE.finditer(line):
                kind = match.group("kind")
                name = match.group("name") or (kind if kind in {"init", "deinit", "subscript"} else "")
                if not name or line_number in protocol_lines and kind not in {"protocol"}:
                    continue
                # A declaration's own spelling is removed below; every remaining
                # token occurrence anywhere in the scanned tree is an apparent use.
                declaration_counts[name] = declaration_counts.get(name, 0) + 1
                declarations.append(
                    Declaration(
                        path=path.relative_to(repo_root).as_posix(),
                        line=line_number,
                        access=match.group("access"),
                        kind=kind,
                        name=name,
                        rationale="No apparent textual reference remains after excluding declaration spellings; external clients, protocol/dynamic dispatch, and reflection are not observable here.",
                    )
                )

    candidates: list[Declaration] = []
    for declaration in declarations:
        name = declaration.name
        apparent_references = tokens.get(name, 0) - declaration_counts.get(name, 0)
        if apparent_references == 0:
            candidates.append(declaration)
    candidates.sort(key=lambda d: (d.path, d.line, d.name, d.kind))
    return candidates, {"swift_files": len(paths), "public_declarations": len(declarations), "candidates": len(candidates)}


def build_report(candidates: list[Declaration], counts: dict[str, int], roots: list[str], excludes: set[str]) -> dict[str, object]:
    return {
        "schema": "unused-public-swift-declarations/v1",
        "deterministic": True,
        "status": "candidate-report",
        "summary": counts,
        "roots": roots,
        "exclusions": sorted(excludes),
        "rationale": [
            "A candidate has no apparent textual reference in the scanned Swift files after its declaration spelling is discounted.",
            "Candidates are not proof of dead code: external clients, protocol requirements, Objective-C/dynamic dispatch, reflection, generated entry points, and linker/runtime use can be legitimate.",
            "Protocol members are excluded because requirements are commonly consumed through conformances or dynamic dispatch that a lexical scan cannot prove.",
            "No API is modified or deleted by this tool.",
        ],
        "candidates": [candidate.as_json() for candidate in candidates],
    }


def build_text_report(report: dict[str, object]) -> str:
    """Render a deterministic plain-text companion report for CI artifacts."""
    summary = report["summary"]
    assert isinstance(summary, dict)
    candidates = report["candidates"]
    assert isinstance(candidates, list)
    lines = [
        "UNUSED PUBLIC SWIFT DECLARATIONS — CANDIDATES ONLY",
        "This deterministic heuristic report is not proof of dead code.",
        "",
        f"Swift files scanned: {summary['swift_files']}",
        f"Public declarations scanned: {summary['public_declarations']}",
        f"Candidates: {summary['candidates']}",
        "",
    ]
    if not candidates:
        lines.append("No candidates found.")
    else:
        lines.append("Candidates:")
        for candidate in candidates:
            assert isinstance(candidate, dict)
            lines.append(
                f"- {candidate['path']}:{candidate['line']} "
                f"{candidate['access']} {candidate['kind']} {candidate['name']}"
            )
    lines.extend(
        [
            "",
            "Review candidates manually; external clients, dynamic dispatch, reflection,",
            "generated entry points, and runtime/linker use are not observable by this scan.",
        ]
    )
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roots", nargs="*", default=list(DEFAULT_ROOTS), help="Swift source roots (default: Sources App)")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--output", "-o", help="Write JSON report to this path instead of stdout")
    parser.add_argument("--text-output", help="Write a deterministic plain-text companion report")
    parser.add_argument("--exclude", action="append", default=[], help="Directory name to exclude; may be repeated")
    args = parser.parse_args(argv)
    repo_root = Path(args.repo_root).resolve()
    roots = [Path(root) if Path(root).is_absolute() else repo_root / root for root in args.roots]
    excludes = DEFAULT_EXCLUDES | set(args.exclude)
    paths = swift_files(roots, excludes)
    candidates, counts = scan(paths, repo_root)
    report = build_report(candidates, counts, [str(root.relative_to(repo_root)) if root.is_relative_to(repo_root) else str(root) for root in roots], excludes)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    if args.text_output:
        text_output = Path(args.text_output)
        text_output.parent.mkdir(parents=True, exist_ok=True)
        text_output.write_text(build_text_report(report), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
