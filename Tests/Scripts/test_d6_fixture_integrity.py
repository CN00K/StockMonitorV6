import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Resources" / "Fixtures"
D6_RAW_FIXTURES = (
    "d6-eastmoney-trends2.raw",
    "d6-eastmoney-daily-kline.raw",
    "d6-cninfo-stock-map.raw",
    "d6-thepaper-news.raw",
    "d6-gov-policy.raw",
    "d6-eastmoney-lhb.raw",
)


class D6FixtureIntegrityTests(unittest.TestCase):
    def test_accessible_recorded_responses_match_sidecar_hash_and_size(self):
        for name in D6_RAW_FIXTURES:
            with self.subTest(fixture=name):
                raw_path = FIXTURES / name
                metadata_path = FIXTURES / f"{name}.json"
                body = raw_path.read_bytes()
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
                self.assertEqual(metadata["http_status"], 200)
                self.assertEqual(metadata["byte_count"], len(body))
                self.assertEqual(metadata["sha256"], hashlib.sha256(body).hexdigest())
                self.assertTrue(metadata["source_url"].startswith("https://"))
                self.assertTrue(metadata["retrieval_timestamp"])


if __name__ == "__main__":
    unittest.main()
