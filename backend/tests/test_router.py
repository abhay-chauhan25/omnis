import unittest

from omnis_backend.router import Target, decide, wants_claude


class RouterTests(unittest.TestCase):
    def test_with_claude_unavailable_everything_is_local(self):
        for text in ("hi", "who won the world cup", "use claude to draft a haiku", "solve this leetcode problem"):
            for override in ("auto", "local", "claude"):
                with self.subTest(text=text, override=override):
                    self.assertIsNot(decide(text, override, cloud_ready=False).target, Target.CLOUD)

    def test_public_questions_go_to_claude_when_it_is_available(self):
        for text in ("hi", "who won the world cup", "what is entropy", "solve this leetcode problem"):
            with self.subTest(text=text):
                decision = decide(text, "auto", cloud_ready=True)
                self.assertIs(decision.target, Target.CLOUD)
                self.assertTrue(decision.reason)

    def test_local_override_never_leaves_the_mac(self):
        for text in ("hi", "use claude to explain this", "ask Claude to prove that this is correct"):
            with self.subTest(text=text):
                decision = decide(text, "local", cloud_ready=True)
                self.assertIsNot(decision.target, Target.CLOUD)
                self.assertIn("you chose local", decision.reason)

    def test_personal_data_never_leaves_the_mac_whatever_else_is_asked(self):
        for override in ("auto", "claude"):
            with self.subTest(override=override):
                decision = decide("use claude to summarise my inbox", override, cloud_ready=True, personal=True)
                self.assertIsNot(decision.target, Target.CLOUD)
                self.assertIn("personal data", decision.reason)

    def test_reasons_say_why_claude_was_chosen(self):
        self.assertEqual(decide("hi", "claude", cloud_ready=True).reason, "you chose Claude")
        self.assertEqual(decide("use Claude to draft a haiku", "auto", cloud_ready=True).reason, "you asked for Claude")
        self.assertEqual(decide("hi", "auto", cloud_ready=True).reason, "it is a public question")

    def test_asking_for_claude_by_name_is_recognised(self):
        for text in ("use Claude to draft a haiku", "ask claude what 2+2 is", "Ask Claude How do monads work",
                     "Use Claude Please explain this", "use Claude Opus for this", "Using Claude, explain monads"):
            with self.subTest(text=text):
                self.assertTrue(wants_claude(text))
        # Naming a person called Claude, or just mentioning the name, is not a request for it.
        for text in ("who is Claude Shannon?", "use claude shannon's work in a sentence",
                     "tell me about using Claude Monet", "Is Claude down today"):
            with self.subTest(text=text):
                self.assertFalse(wants_claude(text))
        self.assertTrue(wants_claude("hi", "claude"))
        self.assertFalse(wants_claude("use claude for this", "local"))

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
