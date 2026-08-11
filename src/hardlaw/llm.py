"""LLM backend interface — pluggable providers.

The LLMBackend Protocol defines the minimum contract for a judge.
Implementations for OpenAI, Ollama, and a Mock backend for testing.
"""

from typing import Protocol
import os
import json


class LLMBackend(Protocol):
    """Protocol for pluggable LLM backends.

    Any object with an async judge(prompt) -> str method satisfies this.
    No base class needed — use structural subtyping.
    """

    async def judge(self, prompt: str) -> str:
        """Send prompt to LLM and return raw response text."""
        ...


class MockLLM:
    """Mock backend that returns pre-scripted responses.

    For testing and examples without external API dependencies.
    Responses are consumed in order; the last response repeats indefinitely.
    """

    def __init__(self, responses: list[str] | None = None):
        self.responses = responses or []
        self.call_count = 0
        self.history: list[str] = []

    async def judge(self, prompt: str) -> str:
        self.history.append(prompt)
        if self.call_count < len(self.responses):
            response = self.responses[self.call_count]
            self.call_count += 1
            return response
        # Default: pass
        self.call_count += 1
        return json.dumps({
            "finding": "none",
            "refuted": False,
            "blocking": "none",
            "confidence": "high",
            "evidence_refs": [{"source": "mock", "location": "N/A", "snippet": "mock"}],
            "reasoning": "Mock default — all checks passed.",
        })


class OpenAI:
    """OpenAI API backend.

    Requires: pip install hardlaw[openai]
    """

    def __init__(self, model: str = "gpt-4o", api_key: str | None = None):
        self.model = model
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")

    async def judge(self, prompt: str) -> str:
        import openai

        client = openai.AsyncOpenAI(api_key=self.api_key)
        response = await client.chat.completions.create(
            model=self.model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.1,
        )
        return response.choices[0].message.content or ""


class Ollama:
    """Local Ollama backend.

    Uses subprocess to call `ollama run`.
    """

    def __init__(self, model: str = "qwen3:0.6b"):
        self.model = model

    async def judge(self, prompt: str) -> str:
        import asyncio

        proc = await asyncio.create_subprocess_exec(
            "ollama", "run", self.model, prompt,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()
        return stdout.decode("utf-8", errors="replace").strip()

class MLX:
    """MLX backend — process-internal, no server, 2-3x faster than Ollama.

    Usage:
        judge = MLX(model="mlx-community/Qwen3.5-35B-A3B-4bit")
        result = await judge.judge("some prompt")
    """

    def __init__(self, model: str = "mlx-community/Qwen3.5-35B-A3B-4bit"):
        self.model = model
        self._loaded = False
        self._model = None
        self._tokenizer = None

    def _ensure_loaded(self):
        if not self._loaded:
            from mlx_lm import load as _load
            self._model, self._tokenizer = _load(self.model)
            self._loaded = True

    async def judge(self, prompt: str) -> str:
        import asyncio
        from mlx_lm import generate
        self._ensure_loaded()
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, lambda: generate(
                self._model, self._tokenizer,
                prompt=prompt, max_tokens=2048))
