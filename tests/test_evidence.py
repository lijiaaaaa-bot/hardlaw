"""Tests for evidence.py — Evidence rules and validation."""

import pytest
from hardlaw.evidence import EvidenceRef, EvidenceRule, EvidencePacket, EvidenceValidator


class TestEvidenceRef:
    def test_create(self):
        ref = EvidenceRef(source="doc.txt", location="line:42", snippet="hello world", kind="text")
        assert ref.source == "doc.txt"
        assert ref.location == "line:42"
        assert ref.snippet == "hello world"
        assert ref.kind == "text"
        assert not ref.is_empty()

    def test_empty_snippet(self):
        ref = EvidenceRef(source="doc.txt")
        assert ref.is_empty()

    def test_default_kind(self):
        ref = EvidenceRef(source="doc.txt", snippet="x")
        assert ref.kind == "text"

    def test_to_dict(self):
        ref = EvidenceRef(source="s", location="l", snippet="x", kind="diff")
        d = ref.to_dict()
        assert d == {"source": "s", "location": "l", "snippet": "x", "kind": "diff"}


class TestEvidenceRule:
    def test_empty_refs_with_min_citations(self):
        rule = EvidenceRule(min_citations=1)
        passed, reason = rule.validate([])
        assert not passed
        assert "no evidence" in reason

    def test_missing_required_source(self):
        rule = EvidenceRule(required_sources=["privacy_policy", "consent_form"])
        refs = [EvidenceRef(source="privacy_policy", snippet="x")]
        passed, reason = rule.validate(refs)
        assert not passed
        assert "consent_form" in reason

    def test_all_required_sources_present(self):
        rule = EvidenceRule(required_sources=["a", "b"])
        refs = [
            EvidenceRef(source="a", snippet="x"),
            EvidenceRef(source="b", snippet="y"),
        ]
        passed, reason = rule.validate(refs)
        assert passed
        assert reason == ""

    def test_min_citations_not_met(self):
        rule = EvidenceRule(min_citations=2)
        refs = [EvidenceRef(source="a", snippet="x")]
        passed, reason = rule.validate(refs)
        assert not passed
        assert "need at least 2" in reason

    def test_unverifiable_empty_snippet(self):
        rule = EvidenceRule(must_be_verifiable=True)
        refs = [EvidenceRef(source="a", snippet="")]  # empty
        passed, reason = rule.validate(refs)
        assert not passed
        assert "empty snippet" in reason

    def test_allow_zero_citations(self):
        rule = EvidenceRule(min_citations=0)
        passed, reason = rule.validate([])
        assert passed


class TestEvidencePacket:
    def test_basic(self):
        packet = EvidencePacket(
            objective="Test objective",
            artifacts={"file1.txt": "content"},
            prior_gaps=["gap 1", "gap 2"],
        )
        prompt = packet.to_prompt_section()
        assert "Test objective" in prompt
        assert "file1.txt" in prompt
        assert "gap 1" in prompt
        assert "gap 2" in prompt
        assert "## OBJECTIVE" in prompt
        assert "## EVIDENCE" in prompt
        assert "## PRIOR GAPS" in prompt

    def test_no_prior_gaps(self):
        packet = EvidencePacket(objective="Test")
        prompt = packet.to_prompt_section()
        assert "PRIOR GAPS" not in prompt


class TestEvidenceValidator:
    def test_validate_existing_snippet(self):
        validator = EvidenceValidator({"doc.txt": "the sky is blue"})
        ref = EvidenceRef(source="doc.txt", snippet="sky is blue")
        assert validator.validate(ref) is True

    def test_validate_missing_snippet(self):
        validator = EvidenceValidator({"doc.txt": "the sky is blue"})
        ref = EvidenceRef(source="doc.txt", snippet="sky is green")
        assert validator.validate(ref) is False

    def test_validate_unknown_source(self):
        validator = EvidenceValidator({})
        ref = EvidenceRef(source="unknown.txt", snippet="x")
        assert validator.validate(ref) is False

    def test_validate_empty_snippet(self):
        validator = EvidenceValidator({"doc.txt": "content"})
        ref = EvidenceRef(source="doc.txt", snippet="")
        assert validator.validate(ref) is False

    def test_validate_all(self):
        validator = EvidenceValidator({"a.txt": "hello", "b.txt": "world"})
        refs = [
            EvidenceRef(source="a.txt", snippet="hello"),
            EvidenceRef(source="b.txt", snippet="world"),
        ]
        all_valid, failures = validator.validate_all(refs)
        assert all_valid
        assert failures == []

    def test_validate_all_with_failures(self):
        validator = EvidenceValidator({"a.txt": "hello"})
        refs = [
            EvidenceRef(source="a.txt", snippet="hello"),
            EvidenceRef(source="b.txt", snippet="missing"),
        ]
        all_valid, failures = validator.validate_all(refs)
        assert not all_valid
        assert len(failures) == 1
        assert "b.txt" in failures[0]

    def test_add_source(self):
        validator = EvidenceValidator()
        validator.add_source("new.txt", "new content")
        ref = EvidenceRef(source="new.txt", snippet="new content")
        assert validator.validate(ref) is True
