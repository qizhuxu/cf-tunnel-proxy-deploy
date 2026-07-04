import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from openai_compat_proxy import normalize_json_for_mimo, normalize_request_body


class NormalizeJsonForMimoTests(unittest.TestCase):
    def test_removes_undefined_string_fields_but_preserves_valid_falsey_values(self):
        payload = {
            "model": "mimo-v2.5",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": False,
            "temperature": 0,
            "top_p": 1,
            "presence_penalty": 0,
            "max_tokens": "[undefined]",
            "tools": "[undefined]",
        }

        normalized = normalize_json_for_mimo(payload)

        self.assertEqual(normalized["stream"], False)
        self.assertEqual(normalized["temperature"], 0)
        self.assertEqual(normalized["presence_penalty"], 0)
        self.assertNotIn("max_tokens", normalized)
        self.assertNotIn("tools", normalized)

    def test_removes_undefined_sentinels_without_dropping_message_content(self):
        payload = {
            "model": "mimo-v2.5",
            "messages": [
                {"role": "system", "content": "test"},
                {"role": "user", "content": "[undefined]", "name": "[undefined]"},
                "[undefined]",
            ],
            "metadata": {"trace": "[undefined]", "keep": "yes"},
        }

        normalized = normalize_json_for_mimo(payload)

        self.assertEqual(
            normalized,
            {
                "model": "mimo-v2.5",
                "messages": [
                    {"role": "user", "content": "System instruction:\ntest\n\nUser message:\n[undefined]"},
                ],
                "metadata": {"keep": "yes"},
            },
        )

    def test_preserves_text_content_blocks(self):
        payload = {
            "model": "mimo-v2.5",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "[undefined]", "mime_type": "[undefined]"},
                    ],
                }
            ],
        }

        normalized = normalize_json_for_mimo(payload)

        self.assertEqual(
            normalized,
            {
                "model": "mimo-v2.5",
                "messages": [
                    {"role": "user", "content": [{"type": "text", "text": "[undefined]"}]},
                ],
            },
        )

    def test_folds_cherry_studio_system_user_request_into_single_user_message(self):
        payload = {
            "model": "mimo-v2.5",
            "user": "[undefined]",
            "max_tokens": "[undefined]",
            "messages": [
                {"role": "system", "content": "test"},
                {"role": "user", "content": "hi"},
            ],
            "tools": "[undefined]",
            "stream": True,
            "stream_options": {"include_usage": True},
        }

        normalized = normalize_json_for_mimo(payload)

        self.assertEqual(
            normalized,
            {
                "model": "mimo-v2.5",
                "messages": [
                    {"role": "user", "content": "System instruction:\ntest\n\nUser message:\nhi"},
                ],
                "stream": True,
                "stream_options": {"include_usage": True},
            },
        )

    def test_folds_multi_turn_history_into_single_user_message(self):
        payload = {
            "model": "mimo-v2.5",
            "messages": [
                {"role": "user", "content": "first"},
                {"role": "assistant", "content": "second"},
                {"role": "user", "content": "third"},
            ],
        }

        normalized = normalize_json_for_mimo(payload)

        self.assertEqual(
            normalized,
            {
                "model": "mimo-v2.5",
                "messages": [
                    {"role": "user", "content": "User message:\nfirst\n\nAssistant message:\nsecond\n\nUser message:\nthird"},
                ],
            },
        )


class NormalizeRequestBodyTests(unittest.TestCase):
    def test_normalizes_chat_completion_json_body(self):
        body = json.dumps(
            {
                "model": "mimo-v2.5",
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": "[undefined]",
            }
        ).encode()

        new_body, headers = normalize_request_body(
            "/v1/chat/completions",
            {"content-type": "application/json", "content-length": str(len(body))},
            body,
        )

        self.assertEqual(json.loads(new_body), {"model": "mimo-v2.5", "messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(headers["Content-Length"], str(len(new_body)))
        self.assertEqual(headers["content-type"], "application/json")

    def test_preserves_upstream_authorization_header_case(self):
        body = b'{"model":"mimo-v2.5","messages":[{"role":"user","content":"hi"}],"tools":"[undefined]"}'

        _, headers = normalize_request_body(
            "/v1/chat/completions",
            {"Content-Type": "application/json", "Authorization": "Bearer upstream-key", "Content-Length": str(len(body))},
            body,
        )

        self.assertEqual(headers["Authorization"], "Bearer upstream-key")
        self.assertEqual(headers["Content-Type"], "application/json")

    def test_leaves_non_chat_paths_unchanged(self):
        body = b'{"max_tokens":"[undefined]"}'

        new_body, headers = normalize_request_body(
            "/v1/models",
            {"content-type": "application/json", "content-length": str(len(body))},
            body,
        )

        self.assertEqual(new_body, body)
        self.assertEqual(headers["content-length"], str(len(body)))


if __name__ == "__main__":
    unittest.main()
