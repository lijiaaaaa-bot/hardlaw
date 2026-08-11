"""Tests for statute.py — Statute definitions and StatuteBook."""

import pytest
from hardlaw.statute import Statute, ViolationType, EscalationRule, StatuteBook


class TestViolationType:
    def test_create(self):
        v = ViolationType("slur", "critical", "Use of recognized slurs")
        assert v.name == "slur"
        assert v.severity == "critical"
        assert v.description == "Use of recognized slurs"

    def test_default_description(self):
        v = ViolationType("test", "low")
        assert v.description == ""


class TestStatute:
    def test_minimal(self):
        s = Statute(name="test_statute")
        assert s.name == "test_statute"
        assert s.default_to_reject is True
        assert s.blocking is True
        assert s.violations == []
        assert s.required_evidence == []

    def test_full(self):
        s = Statute(
            name="gdpr_consent",
            description="GDPR consent requirements",
            threshold={"confidence_min": "high"},
            required_evidence=["consent_mechanism", "privacy_policy"],
            violations=[
                ViolationType("missing_consent", "critical"),
                ViolationType("vague_purpose", "high"),
            ],
            escalation=EscalationRule(max_violations=2, action="block"),
            default_to_reject=True,
            blocking=True,
        )
        assert len(s.violations) == 2
        assert s.threshold == {"confidence_min": "high"}
        assert s.escalation.max_violations == 2

    def test_to_dict(self):
        s = Statute(name="test", description="desc", required_evidence=["ev1"])
        d = s.to_dict()
        assert d["name"] == "test"
        assert d["required_evidence"] == ["ev1"]
        assert d["default_to_reject"] is True

    def test_from_dict_roundtrip(self):
        original = Statute(
            name="test_roundtrip",
            description="test desc",
            threshold={"min": "high"},
            required_evidence=["a", "b"],
            violations=[ViolationType("v1", "critical", "desc")],
            escalation=EscalationRule(max_violations=5, action="flag", escalate_to="other"),
            default_to_reject=False,
            blocking=False,
        )
        d = original.to_dict()
        restored = Statute.from_dict(d)
        assert restored.name == original.name
        assert restored.description == original.description
        assert restored.threshold == original.threshold
        assert [r.evidence for r in restored.required_evidence] == [r.evidence if hasattr(r, 'evidence') else r for r in original.required_evidence]
        assert len(restored.violations) == 1
        assert restored.violations[0].name == "v1"
        assert restored.escalation.max_violations == 5
        assert restored.escalation.action == "flag"
        assert restored.default_to_reject is False
        assert restored.blocking is False

    def test_from_dict_minimal(self):
        d = {"name": "minimal"}
        s = Statute.from_dict(d)
        assert s.name == "minimal"
        assert s.description == ""
        assert s.violations == []
        assert s.default_to_reject is True


class TestStatuteBook:
    def test_empty(self):
        book = StatuteBook()
        assert len(book) == 0
        assert book.list_names() == []

    def test_add_and_get(self):
        book = StatuteBook()
        s = Statute(name="test")
        book.add(s)
        assert len(book) == 1
        assert book.get("test") is s
        assert book.get("nonexistent") is None
        assert "test" in book
        assert "nonexistent" not in book

    def test_replace(self):
        book = StatuteBook()
        s1 = Statute(name="test", description="first")
        s2 = Statute(name="test", description="second")
        book.add(s1)
        book.add(s2)
        assert book.get("test").description == "second"

    def test_get_all(self):
        book = StatuteBook([
            Statute(name="a"),
            Statute(name="b"),
            Statute(name="c"),
        ])
        result = book.get_all(["a", "c", "nonexistent"])
        assert len(result) == 2
        assert result[0].name == "a"
        assert result[1].name == "c"

    def test_to_dict_and_from_dict(self):
        book = StatuteBook([
            Statute(name="s1", description="first"),
            Statute(name="s2", description="second"),
        ])
        d = book.to_dict()
        restored = StatuteBook.from_dict(d)
        assert len(restored) == 2
        assert restored.get("s1").description == "first"
        assert restored.get("s2").description == "second"

    def test_list_names(self):
        book = StatuteBook([
            Statute(name="z"),
            Statute(name="a"),
            Statute(name="m"),
        ])
        # Maintains insertion order
        assert book.list_names() == ["z", "a", "m"]
