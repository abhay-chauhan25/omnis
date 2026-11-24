import unittest

from omnis_backend.router import Target, decide


class RouterTests(unittest.TestCase):
    def test_reasons_say_why_a_request_was_kept_local(self):
        self.assertIn("you chose local", decide("hi", "local").reason)
        self.assertIn("personal data", decide("summarise my inbox", "auto", personal=True).reason)
        self.assertEqual(decide("hi").reason, "it is a short, simple request")

    def test_local_lane_still_tells_light_from_moderate(self):
        self.assertIs(decide("What is the capital of France?").target, Target.LIGHT)
        for text in ("Compare SQLite and Postgres", "Write a function that reverses a list",
                     "What is the time complexity of heapsort?", "word " * 41):
            with self.subTest(text=text[:30]):
                self.assertIs(decide(text).target, Target.MODERATE)

    def test_same_input_same_answer(self):
        self.assertEqual(decide("Compare A and B", "auto", True), decide("Compare A and B", "auto", True))


if __name__ == "__main__":
    unittest.main()
