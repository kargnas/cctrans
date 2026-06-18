# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "mlx-lm>=0.29.0",
# ]
# ///

import json
import sys
from typing import Any


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        text = str(payload["text"]).strip()
        source_language = str(payload.get("source_language") or "Auto").strip()
        target_language = str(payload.get("target_language") or "Korean").strip()
        model_id = str(payload.get("model_id") or "mlx-community/Hy-MT2-1.8B-4bit").strip()
        prompt = str(payload.get("prompt") or "").strip() or make_prompt(
            text=text,
            source_language=source_language,
            target_language=target_language,
        )
        if not text:
            raise ValueError("No text was provided.")

        translation = clean_translation(translate(model_id=model_id, prompt=prompt))
        print(json.dumps({"translation": translation}, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        return 1


def translate(model_id: str, prompt: str) -> str:
    from mlx_lm import generate, load

    model, tokenizer = load(model_id)
    formatted_prompt = format_prompt(tokenizer=tokenizer, prompt=prompt)
    output = generate(
        model,
        tokenizer,
        prompt=formatted_prompt,
        max_tokens=2048,
        verbose=False,
    )
    return clean_output(prompt=formatted_prompt, output=output)


def format_prompt(tokenizer: Any, prompt: str) -> str:
    messages = [{"role": "user", "content": prompt}]
    apply_chat_template = getattr(tokenizer, "apply_chat_template", None)
    if apply_chat_template is None:
        return prompt

    try:
        return apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=False,
        )
    except Exception:
        return prompt


def clean_output(prompt: str, output: str) -> str:
    cleaned = output.strip()
    if cleaned.startswith(prompt):
        cleaned = cleaned[len(prompt) :].strip()
    return cleaned


def make_prompt(text: str, source_language: str, target_language: str) -> str:
    return (
        f"Translate {source_language} to {target_language}. Preserve paragraph breaks and line breaks.\n\n"
        f"{text}"
    )


def clean_translation(text: str) -> str:
    cleaned = strip_prompt_wrapper_echo(text.strip())
    for instruction in LEAKED_PROMPT_INSTRUCTIONS:
        cleaned = cleaned.replace(instruction, "")
    lines = [
        line
        for line in cleaned.splitlines()
        if not is_removable_prompt_echo_line(line)
    ]
    cleaned = "\n".join(lines).strip()
    cleaned = strip_leading_translation_label(cleaned)
    return cleaned


def strip_prompt_wrapper_echo(text: str) -> str:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == ">>>":
            remainder = "\n".join(lines[index + 1 :]).strip()
            if remainder:
                return remainder
            break

    for index, line in enumerate(lines[:6]):
        label_length = leading_translation_label_length(line.strip())
        if label_length is not None:
            same_line = line.strip()[label_length:].strip()
            following = "\n".join(lines[index + 1 :]).strip()
            return "\n".join(part for part in (same_line, following) if part).strip()

    return text.strip()


def strip_leading_translation_label(text: str) -> str:
    label_length = leading_translation_label_length(text)
    if label_length is None:
        return text
    remainder = text[label_length:].strip()
    return remainder or text


def leading_translation_label_length(text: str) -> int | None:
    normalized = text.lower()
    for label in TRANSLATION_LABELS:
        if normalized.startswith(label.lower()):
            return len(label)
    return None


def is_removable_prompt_echo_line(line: str) -> bool:
    stripped = line.strip()
    return stripped in PROMPT_ECHO_LINES or stripped.lower() in LEAKED_PROMPT_INSTRUCTION_LINES


TRANSLATION_LABELS = (
    "Translation:",
    "Translated text:",
    "Translated result:",
    "Result:",
    "번역:",
    "번역문:",
    "번역 결과:",
    "翻訳:",
    "翻译:",
    "譯文:",
    "译文:",
)
PROMPT_ECHO_LINES = {"<<<", ">>>", "<selected_text>", "</selected_text>", "Text:"}
LEAKED_PROMPT_INSTRUCTIONS = [
    "Note that you should only output the translated result without any additional explanation:",
    "Note that you should only output the translated result without any additional explanation.",
    "Only output the translated result without any additional explanation:",
    "Only output the translated result without any additional explanation.",
]
LEAKED_PROMPT_INSTRUCTION_LINES = {value.strip().lower() for value in LEAKED_PROMPT_INSTRUCTIONS}


if __name__ == "__main__":
    raise SystemExit(main())
