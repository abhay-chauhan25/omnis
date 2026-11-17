import unittest

from omnis_backend.router import Target, decide


class RouterTests(unittest.TestCase):
    def target(self, text, override="auto"):
        return decide(text, override).target

    def test_short_simple_requests_use_the_light_model(self):
        for text in ("What is the capital of France?", "define entropy", "hi"):
            with self.subTest(text=text):
                self.assertIs(self.target(text), Target.LIGHT)

    def test_planning_code_and_summaries_use_the_moderate_model(self):
        for text in (
            "Compare SQLite and Postgres for a small app",
            "Write a function that reverses a list",
            "Give me a step-by-step plan to learn Swift",
            "Summarize the main ideas of stoicism",
            "explain why the sky is blue",
            "what are the tradeoffs of microservices",
        ):
            with self.subTest(text=text):
                self.assertIs(self.target(text), Target.MODERATE)

    def test_long_requests_use_the_moderate_model(self):
        self.assertIs(self.target("word " * 41), Target.MODERATE)
        self.assertIs(self.target("word " * 40), Target.LIGHT)

    def test_hard_topics_stay_local_on_the_larger_model_and_are_flagged(self):
        for text in (
            "Explain the methodology of this research paper",
            "Solve this leetcode problem about intervals",
            "What is the time complexity of heapsort?",
            "prove that this loop terminates",
            "read the PDF in Downloads",
            "summarise my paper on transformers",
        ):
            with self.subTest(text=text):
                decision = decide(text)
                self.assertIs(decision.target, Target.MODERATE)
                self.assertIn("Claude", decision.reason)

    def test_nothing_reaches_claude_unless_asked_for(self):
        for text in (
            "Summarize this article",
            "Convert the pdf to text",
            "What is dynamic programming",
            "I can prove that I paid",
            "Open the paper folder",
            "what is the methodology of the scientific method",
            "Is Claude down today",
            "who is Claude Monet",
        ):
            with self.subTest(text=text):
                self.assertIsNot(self.target(text), Target.CLOUD)

    def test_everyday_questions_stay_on_this_mac(self):
        for text in (
            "What size is A4 paper?",
            "is toilet paper recyclable",
            "how do I merge two pdf files",
            "what is an algorithm",
            "a proof of concept for my app",
            "I need to prove I live here for a bank",
            "tell me about using Claude Monet",
            "ask Claude Shannon about information theory",
            "chat with Claude Debussy music",
        ):
            with self.subTest(text=text):
                self.assertIsNot(self.target(text), Target.CLOUD)

    def test_asking_for_claude_by_name(self):
        for text in (
            "use Claude to draft a haiku",
            "ask claude what 2+2 is",
            "Ask Claude How do monads work",
            "Use Claude Please explain this",
            "use Claude Opus for this",
            "Using Claude, explain monads",
            "Ask Claude: what is X",
        ):
            with self.subTest(text=text):
                self.assertIs(self.target(text), Target.CLOUD)
        # Merely mentioning the name is not a request for it.
        self.assertIs(self.target("who is Claude Shannon?"), Target.LIGHT)
        self.assertIs(self.target("use claude shannon's work in a sentence"), Target.LIGHT)

    def test_local_override_never_leaves_the_mac(self):
        for text in ("use claude to explain this research paper", "ask Claude to prove that this is correct"):
            with self.subTest(text=text):
                decision = decide(text, "local")
                self.assertIsNot(decision.target, Target.CLOUD)
                self.assertIn("you chose local", decision.reason)

    def test_claude_override_always_wins(self):
        decision = decide("hi", "claude")
        self.assertIs(decision.target, Target.CLOUD)
        self.assertEqual(decision.reason, "you chose Claude")

    def test_same_input_same_answer_and_a_reason_is_given(self):
        first = decide("Compare A and B")
        self.assertEqual(first, decide("Compare A and B"))
        self.assertTrue(first.reason)


if __name__ == "__main__":
    unittest.main()
