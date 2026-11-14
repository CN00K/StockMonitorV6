#!/usr/bin/env python3
import importlib.util
import json
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "report-unused-public-swift-declarations.py"
spec = importlib.util.spec_from_file_location("unused_public_scanner", SCRIPT)
scanner = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = scanner
spec.loader.exec_module(scanner)


class ScannerTests(unittest.TestCase):
    def scan_fixture(self):
        fixture = Path(__file__).parent / "Fixtures" / "scanner-fixture.swift"
        return scanner.scan([fixture], fixture.parents[3])

    def test_reports_only_unreferenced_public_declarations(self):
        candidates, counts = self.scan_fixture()
        names = {(item.name, item.kind) for item in candidates}
        self.assertIn(("UnusedType", "struct"), names)
        self.assertIn(("unusedFunction", "func"), names)
        self.assertIn(("unusedValue", "let"), names)
        self.assertNotIn(("UsedType", "struct"), names)
        self.assertNotIn(("usedFunction", "func"), names)
        self.assertNotIn(("PublicContract", "protocol"), names)
        self.assertEqual(counts["swift_files"], 1)

    def test_comments_and_strings_do_not_count_as_references(self):
        candidates, _ = self.scan_fixture()
        names = {item.name for item in candidates}
        self.assertIn("unusedFunction", names)
        self.assertIn("unusedValue", names)

    def test_protocol_requirements_are_excluded(self):
        candidates, _ = self.scan_fixture()
        self.assertNotIn("protocolRequirement", {item.name for item in candidates})

    def test_report_is_sorted_and_json_shape_is_stable(self):
        candidates, counts = self.scan_fixture()
        report = scanner.build_report(candidates, counts, ["Tests/Scripts/Fixtures"], {".build"})
        self.assertTrue(report["deterministic"])
        self.assertEqual(report["status"], "candidate-report")
        rows = report["candidates"]
        self.assertEqual(rows, sorted(rows, key=lambda row: (row["path"], row["line"], row["name"], row["kind"])))
        encoded = json.dumps(report, sort_keys=True)
        self.assertEqual(encoded, json.dumps(report, sort_keys=True))

    def test_text_report_is_deterministic_and_labels_candidates_not_proof(self):
        candidates, counts = self.scan_fixture()
        report = scanner.build_report(candidates, counts, ["Tests/Scripts/Fixtures"], {".build"})
        text = scanner.build_text_report(report)
        self.assertIn("CANDIDATES ONLY", text)
        self.assertIn("not proof of dead code", text)
        self.assertIn("Tests/Scripts/Fixtures/scanner-fixture.swift:2", text)
        self.assertEqual(text, scanner.build_text_report(report))


if __name__ == "__main__":
    unittest.main()
