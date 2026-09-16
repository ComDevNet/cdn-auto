import csv
import json
import tempfile
import unittest
from pathlib import Path

import assessment


class AssessmentAnswerSyncTests(unittest.TestCase):
    def test_same_named_assessments_with_identical_questions_share_scheme(self):
        payload = {
            "assessmentsById": {
                "standalone-id": {"title": "Faith"},
                "module-id": {"title": "Faith"},
            },
            "questionsByAssessmentId": {
                "standalone-id": [{"id": "a-1", "prompt": "What is faith?", "options": ["A", "B"]}],
                "module-id": [{"id": "b-9", "prompt": "What is faith?", "options": ["A", "B"]}],
            },
            "richQuestionsByAssessmentId": {},
            "data": [],
        }

        resolved = assessment.automatic_assessment_id_map(payload, {}, "Example Org")

        self.assertEqual(resolved["standalone-id"], "faith")
        self.assertEqual(resolved["module-id"], "faith")

    def test_same_named_assessments_with_different_questions_get_separate_schemes(self):
        payload = {
            "assessmentsById": {
                "old-standalone": {"title": "Faith"},
                "new-module": {"title": "Faith"},
            },
            "questionsByAssessmentId": {
                "old-standalone": [{"id": "q1", "prompt": "What is faith?"}],
                "new-module": [{"id": "q1", "prompt": "Who demonstrated faith?"}],
            },
            "richQuestionsByAssessmentId": {},
            "data": [
                {"assessmentId": "new-module", "createdAt": "2026-09-16T12:00:00Z"},
                {"assessmentId": "old-standalone", "createdAt": "2026-09-01T12:00:00Z"},
            ],
        }

        resolved = assessment.automatic_assessment_id_map(payload, {}, "Example Org")

        self.assertEqual(resolved["old-standalone"], "faith")
        self.assertRegex(resolved["new-module"], r"^faith-[0-9a-f]{8}$")
        self.assertNotEqual(resolved["new-module"], resolved["old-standalone"])

    def test_title_mapping_is_split_when_same_name_has_different_questions(self):
        payload = {
            "assessmentsById": {
                "source-a": {"title": "Faith"},
                "source-b": {"title": "Faith"},
            },
            "questionsByAssessmentId": {
                "source-a": [{"prompt": "Question A"}],
                "source-b": [{"prompt": "Question B"}],
            },
            "richQuestionsByAssessmentId": {},
            "data": [
                {"assessmentId": "source-a", "createdAt": "2026-01-01T00:00:00Z"},
                {"assessmentId": "source-b", "createdAt": "2026-02-01T00:00:00Z"},
            ],
        }
        mapping = {
            "faith": {
                "source_assessment_name": "Faith",
                "assessmentId": "faith-custom",
                "parentOrg": "Example Org",
            }
        }

        resolved = assessment.automatic_assessment_id_map(payload, mapping, "Default Org")
        first = assessment.resolve_assessment_mapping(
            mapping,
            "Default Org",
            assessment_id="source-a",
            assessment_title="Faith",
            automatic_assessment_ids=resolved,
        )
        second = assessment.resolve_assessment_mapping(
            mapping,
            "Default Org",
            assessment_id="source-b",
            assessment_title="Faith",
            automatic_assessment_ids=resolved,
        )

        self.assertEqual(first, ("faith-custom", "Example Org", True))
        self.assertRegex(second[0], r"^faith-custom-[0-9a-f]{8}$")
        self.assertEqual(second[1], "Example Org")

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

    def test_matches_rich_questions_to_database_ids_by_prompt_when_database_order_differs(self):
        questions = assessment.merge_question_definitions(
            [
                {"question": "First question", "questionType": "short_answer"},
                {"question": "Second question", "questionType": "short_answer"},
            ],
            [
                {"id": "second-id", "prompt": "Second question"},
                {"id": "first-id", "prompt": "First question"},
            ],
        )

        self.assertEqual([question["id"] for question in questions], ["first-id", "second-id"])

    def test_uses_review_question_id_before_review_array_position(self):
        answers = {
            "review": [
                {"questionId": "second-id", "selectedAnswer": "Second answer"},
                {"questionId": "first-id", "selectedAnswer": "First answer"},
            ],
            "selections": {
                "first-id": "First answer",
                "second-id": "Second answer",
            },
        }

        self.assertEqual(
            assessment.selected_answer_for(answers, {"id": "first-id"}, 0),
            "First answer",
        )

    def test_unanswered_question_does_not_borrow_another_questions_selection(self):
        answers = {
            "review": [
                {"questionId": "answered-id", "selectedAnswer": "Answered"},
                {"questionId": "blank-id", "selectedAnswer": ""},
            ],
            "selections": {"answered-id": "Answered"},
        }

        self.assertEqual(
            assessment.selected_answer_for(answers, {"id": "blank-id"}, 0),
            "",
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
