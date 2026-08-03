"""Tests for verdict.py — Verdict parsing and fingerprint computation."""

import pytest
from hardlaw.verdict import (
    Verdict,
    Finding,
    Confidence,
    VerdictParser,
    compute_fingerprint,
    BLOCKING_NONE,
    BLOCKING_CONTRADICTION,
    BLOCKING_UNVERIFIABLE,
)


class TestConfidence:
    def test_parse_high(self):
        assert Confidence.parse("high") == Confidence.HIGH

    def test_parse_medium(self):
        assert Confidence.parse("medium") == Confidence.MEDIUM

    def test_parse_low(self):
        assert Confidence.parse("low") == Confidence.LOW

    def test_parse_unknown(self):
        assert Confidence.parse("garbage") == Confidence.UNKNOWN

    def test_parse_case_insensitive(self):
        assert Confidence.parse("HIGH") == Confidence.HIGH
        assert Confidence.parse("Medium") == Confidence.MEDIUM


class TestFinding:
    def test_create(self):
        f = Finding(kind="bug", location="file.py:10", detail="null pointer")
        assert f.kind == "bug"
        assert not f.is_empty()

    def test_empty(self):
        f = Finding()
        assert f.is_empty()

    def test_partial_not_empty(self):
        f = Finding(kind="bug")
        # kind is not empty, so finding is not considered empty
        # (even though location and detail are missing)
        assert not f.kind.strip() == "" or not f.is_empty()
        # Actually is_empty checks all three:
        assert f.is_empty() == (not f.kind.strip() and not f.location.strip() and not f.detail.strip())


class TestVerdict:
    def test_default(self):
        v = Verdict()
        assert v.refuted is True  # default to reject
        assert v.confidence == Confidence.MEDIUM
        assert v.blocking is False

    def test_is_decisive(self):
        v = Verdict(refuted=True, confidence=Confidence.HIGH, blocking=False)
        assert v.is_decisive() is True

    def test_is_decisive_not_refuted(self):
        v = Verdict(refuted=False, confidence=Confidence.HIGH, blocking=False)
        assert v.is_decisive() is False

    def test_is_decisive_blocking(self):
        v = Verdict(refuted=True, confidence=Confidence.HIGH, blocking=True)
        assert v.is_decisive() is False  # blocking → not decisive (needs full panel)

    def test_is_decisive_low_confidence(self):
        v = Verdict(refuted=True, confidence=Confidence.MEDIUM, blocking=False)
        assert v.is_decisive() is False

    def test_to_dict(self):
        v = Verdict(finding="test", refuted=True, reasoning="because")
        d = v.to_dict()
        assert d["finding"] == "test"
        assert d["refuted"] is True
        assert d["reasoning"] == "because"


class TestVerdictParser:
    def test_parse_valid_json(self):
        raw = '{"finding": "gap", "refuted": true, "confidence": "high", "blocking": "none", "evidence_refs": [], "findings": [], "reasoning": "test"}'
        v = VerdictParser.parse(raw)
        assert v.finding == "gap"
        assert v.refuted is True
        assert v.confidence == Confidence.HIGH
        assert v.fallback_note is None

    def test_parse_json_in_code_block(self):
        raw = '''```json
{"finding": "none", "refuted": false, "confidence": "medium", "blocking": "none", "evidence_refs": [], "findings": [], "reasoning": "ok"}
```'''
        v = VerdictParser.parse(raw)
        assert v.finding == "none"
        assert v.refuted is False

    def test_parse_terminal_token_refuted(self):
        raw = "Refuted"
        v = VerdictParser.parse(raw)
        assert v.refuted is True
        assert v.fallback_note is not None
        assert "terminal token" in v.fallback_note

    def test_parse_terminal_token_not_refuted(self):
        raw = "Not Refuted"
        v = VerdictParser.parse(raw)
        assert v.refuted is False
        assert v.fallback_note is not None

    def test_parse_terminal_token_with_fence(self):
        raw = "```\nRefuted\n```"
        v = VerdictParser.parse(raw)
        assert v.refuted is True

    def test_parse_default_to_reject(self):
        raw = "some random prose without JSON or terminal token"
        v = VerdictParser.parse(raw)
        assert v.refuted is True  # fail-closed
        assert v.fallback_note is not None
        assert "terminal token unrecognised" in v.fallback_note

    def test_parse_empty_string(self):
        v = VerdictParser.parse("")
        assert v.refuted is True

    def test_parse_with_evidence_refs(self):
        raw = (
            '{"finding": "violation", "refuted": true, "confidence": "high",'
            '"blocking": "none",'
            '"evidence_refs": [{"source": "doc.txt", "location": "line 5", "snippet": "bad words", "kind": "text"}],'
            '"findings": [{"kind": "gap", "location": "doc.txt:5", "detail": "bad words found"}],'
            '"reasoning": "Found violation"}'
        )
        v = VerdictParser.parse(raw)
        assert len(v.evidence_refs) == 1
        assert v.evidence_refs[0].source == "doc.txt"
        assert v.evidence_refs[0].snippet == "bad words"
        assert len(v.findings) == 1
        assert v.findings[0].kind == "gap"

    def test_parse_blocking_contradiction(self):
        raw = '{"finding": "contradiction", "refuted": true, "blocking": "contradiction", "confidence": "high", "evidence_refs": [], "findings": [], "reasoning": "test"}'
        v = VerdictParser.parse(raw)
        assert v.blocking is True
        assert v.blocking_kind == BLOCKING_CONTRADICTION

    def test_parse_blocking_unverifiable(self):
        raw = '{"finding": "unverifiable", "refuted": true, "blocking": "unverifiable", "confidence": "high", "evidence_refs": [], "findings": [], "reasoning": "test"}'
        v = VerdictParser.parse(raw)
        assert v.blocking is True
        assert v.blocking_kind == BLOCKING_UNVERIFIABLE

    def test_parse_blocking_unknown_normalizes_to_none(self):
        raw = '{"finding": "x", "refuted": true, "blocking": "some_future_value", "confidence": "high", "evidence_refs": [], "findings": [], "reasoning": "test"}'
        v = VerdictParser.parse(raw)
        assert v.blocking_kind == BLOCKING_NONE  # normalizes unknown values
        assert v.blocking is False


class TestComputeFingerprint:
    def test_empty_findings(self):
        assert compute_fingerprint([]) == ""

    def test_stable_output(self):
        findings = [
            Finding(kind="bug", location="a.py:1", detail="issue"),
            Finding(kind="gap", location="b.py:2", detail="missing"),
        ]
        fp1 = compute_fingerprint(findings)
        fp2 = compute_fingerprint(findings)
        assert fp1 == fp2
        assert len(fp1) == 16  # first 16 hex chars

    def test_order_independent(self):
        f1 = [
            Finding(kind="a", location="1", detail="x"),
            Finding(kind="b", location="2", detail="y"),
        ]
        f2 = [
            Finding(kind="b", location="2", detail="y"),
            Finding(kind="a", location="1", detail="x"),
        ]
        assert compute_fingerprint(f1) == compute_fingerprint(f2)

    def test_different_gaps_different_fingerprints(self):
        f1 = [Finding(kind="bug", location="a.py:1", detail="x")]
        f2 = [Finding(kind="bug", location="a.py:1", detail="y")]
        assert compute_fingerprint(f1) != compute_fingerprint(f2)

    def test_empty_findings_skipped(self):
        f = [Finding(kind="", location="", detail=""), Finding(kind="bug", location="a", detail="x")]
        fp = compute_fingerprint(f)
        # Should only include the non-empty finding
        assert len(fp) == 16
