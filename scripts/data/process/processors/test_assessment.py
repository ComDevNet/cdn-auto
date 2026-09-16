import csv
import json
import tempfile
import unittest
from pathlib import Path

import assessment


class AssessmentAnswerSyncTests(unittest.TestCase):
    def test_keeps_rich_review_answers_without_numeric_selected_index(self):
        answers = {
            "review": [
                {"selectedIndex": None, "selectedAnswer": "believing and committing"},
                {"selectedIndex": None, "selectedAnswer": "2"},
                {
                    "selectedIndex": None,
                    "selectedAnswer": "Merriam-Webster: Allegiance; Billy Graham: Believing",
                },
            ],
            "selections": {
                "question-1": "believing and committing",
                "question-2": "2",
                "question-3": "Merriam-Webster: Allegiance; Billy Graham: Believing",
            },
        }
        questions = [
            {"id": "question-1"},
            {"id": "question-2"},
            {"id": "question-3"},
        ]

        self.assertEqual(
            [assessment.selected_answer_for(answers, question, index) for index, question in enumerate(questions)],
            [
                "believing and committing",
                "2",
                "Merriam-Webster: Allegiance; Billy Graham: Believing",
            ],
        )

    def test_preserves_zero_index_and_merges_database_ids_into_rich_questions(self):
        questions = assessment.merge_question_definitions(
            [
                {
                    "order": 1,
                    "question": "Region?",
                    "questionType": "multiple_choice",
                    "choices": ["West", "East"],
                }
            ],
            [{"id": "question-1", "prompt": "Region?", "options": ["West", "East"]}],
        )

        self.assertEqual(questions[0]["id"], "question-1")
        self.assertEqual(questions[0]["options"], ["West", "East"])
        self.assertEqual(
            assessment.selected_answer_for(
                {"selections": {"question-1": 0}},
                questions[0],
                0,
            ),
            "West",
        )

    def test_writes_all_rich_answer_types_to_the_synced_csv(self):
        questions = assessment.merge_question_definitions(
            [
                {"question": "Explain faith", "questionType": "short_answer"},
                {
                    "question": "Region?",
                    "questionType": "multiple_choice",
                    "choices": ["West", "East"],
                },
                {"question": "Confidence?", "questionType": "linear_scale"},
                {"question": "Match sources", "questionType": "multiple_choice_grid"},
                {"question": "Match attributes", "questionType": "checkbox_grid"},
            ],
            [
                {"id": "q1"},
                {"id": "q2"},
                {"id": "q3"},
                {"id": "q4"},
                {"id": "q5"},
            ],
        )
        answers = {
            "review": [
                {"selectedIndex": None, "selectedAnswer": "Believing and committing"},
                {"selectedIndex": 1, "selectedAnswer": "East"},
                {"selectedIndex": None, "selectedAnswer": "2"},
                {"selectedIndex": None, "selectedAnswer": "Source A: Meaning A"},
                {"selectedIndex": None, "selectedAnswer": "Guide: Trait 1, Trait 2"},
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "result.csv"
            assessment.write_result_csv(path, "2026-09-16T10:00:00Z", questions, answers)
            with path.open(encoding="utf-8", newline="") as handle:
                rows = list(csv.reader(handle))

        self.assertEqual(
            rows[1][1:],
            [
                "Believing and committing",
                "East",
                "2",
                "Source A: Meaning A",
                "Guide: Trait 1, Trait 2",
            ],
        )

    def test_old_state_ids_are_preserved_during_format_upgrade(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "state.json"
            path.write_text(json.dumps({"uploadedIds": ["old-result"]}), encoding="utf-8")
            self.assertEqual(assessment.load_state(path), {"old-result"})

            assessment.save_state(path, {"old-result", "new-result"})
            self.assertEqual(assessment.load_state(path), {"old-result", "new-result"})
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["formatVersion"], assessment.RESULT_FORMAT_VERSION)


if __name__ == "__main__":
    unittest.main()
