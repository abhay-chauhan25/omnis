import unittest

from omnis_speech.text import DEFAULT_VOICE, MAX_SAY_CHARACTERS, sentences, speed_or_default, voice_or_default


class SpeechTextTests(unittest.TestCase):
    def test_splits_into_sentences(self):
        self.assertEqual(sentences("Oh nice. You're free after four! Want the gym?"),
                         ["Oh nice.", "You're free after four!", "Want the gym?"])

    def test_keeps_a_sentence_with_no_ending(self):
        self.assertEqual(sentences("  just this  "), ["just this"])

    def test_drops_what_has_nothing_to_say(self):
        self.assertEqual(sentences("... !  ?"), [])
        self.assertEqual(sentences(""), [])

    def test_does_not_split_inside_a_number(self):
        self.assertEqual(sentences("It is 3.5 miles."), ["It is 3.5 miles."])

    def test_limits_length(self):
        self.assertLessEqual(sum(len(part) for part in sentences("word " * 5000)), MAX_SAY_CHARACTERS)

    def test_only_known_voices(self):
        self.assertEqual(voice_or_default("af_heart"), "af_heart")
        self.assertEqual(voice_or_default("../../etc"), DEFAULT_VOICE)
        self.assertEqual(voice_or_default(None), DEFAULT_VOICE)

    def test_speed_is_kept_in_range(self):
        self.assertEqual(speed_or_default(1.08), 1.08)
        self.assertEqual(speed_or_default(9), 1.5)
        self.assertEqual(speed_or_default("fast"), 1.0)
        self.assertEqual(speed_or_default(True), 1.0)


if __name__ == "__main__":
    unittest.main()
