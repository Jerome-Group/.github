"""Declared assistance on merged PRs, not effort or application telemetry."""

import re
from collections import Counter

LABELS = (
    "Claude",
    "Codex / OpenAI",
    "Both",
    "Other / mixed",
    "Unassisted",
    "Undeclared",
)


def classify(body):
    trailers = []
    for line in reversed((body or "").strip().splitlines()):
        match = re.fullmatch(r"([A-Za-z][A-Za-z-]*):\s*(.+)", line.strip())
        if not match:
            break
        trailers.append((match[1].lower(), match[2].strip().lower()))
    models = [value for key, value in trailers if key == "assisted-by"]
    if not models:
        return "Undeclared"
    if all(model == "none" for model in models):
        return "Unassisted"
    families = set()
    for model in models:
        if model == "none":
            families.add("other")
            continue
        matched = False
        if re.search(r"\b(claude|anthropic)\b", model):
            families.add("claude")
            matched = True
        if re.search(r"\b(codex|openai|gpt[- ]?\d|o[134](?:[- ]|\b))", model):
            families.add("openai")
            matched = True
        if not matched or re.search(
            r"\b(gemini|copilot|deepseek|llama|mistral)\b", model
        ):
            families.add("other")
    if families == {"claude"}:
        return "Claude"
    if families == {"openai"}:
        return "Codex / OpenAI"
    if families == {"claude", "openai"}:
        return "Both"
    return "Other / mixed"


def summarize_assistance(pulls):
    counts = Counter(classify(pull.get("body")) for pull in pulls if pull["mergedAt"])
    return {label: counts[label] for label in LABELS}
