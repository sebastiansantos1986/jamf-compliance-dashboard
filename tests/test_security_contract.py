import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "jamf_collect_os_versions.sh").read_text(encoding="utf-8")


class SecurityContractTests(unittest.TestCase):
    def test_credentials_are_not_hardcoded(self):
        self.assertIn('JAMF_CLIENT_SECRET="${JAMF_CLIENT_SECRET:-}"', SCRIPT)
        self.assertNotIn('JAMF_CLIENT_SECRET="your-', SCRIPT)

    def test_unknown_versions_are_retained(self):
        self.assertIn("display_version = row[3] or 'Unknown'", SCRIPT)

    def test_embedded_json_is_script_safe(self):
        self.assertIn("replace('<', '\\\\u003c')", SCRIPT)

    def test_user_values_are_html_escaped(self):
        self.assertIn("function esc(value)", SCRIPT)
        self.assertIn("esc(c.name)", SCRIPT)

    def test_api_calls_fail_and_retry(self):
        self.assertIn("--fail-with-body", SCRIPT)
        self.assertIn("--retry 3", SCRIPT)


if __name__ == "__main__":
    unittest.main()
