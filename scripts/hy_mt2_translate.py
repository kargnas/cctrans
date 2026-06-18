# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "accelerate",
#   "protobuf",
#   "sentencepiece",
#   "torch",
#   "transformers>=4.56.0",
# ]
# ///

import json
import sys
from pathlib import Path
from typing import Any


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        text = str(payload["text"]).strip()
        target_language = str(payload.get("target_language") or "Korean").strip()
        model_id = str(payload.get("model_id") or "tencent/Hy-MT2-30B-A3B").strip()
        prompt = str(payload.get("prompt") or "").strip() or make_prompt(
            text=text,
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
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    offload_folder = Path.home() / ".cache" / "cctrans" / "offload" / model_id.replace("/", "--")
    offload_folder.mkdir(parents=True, exist_ok=True)
    device_map: str | dict[str, str] = "auto"
    if "30B-A3B" in model_id and not torch.cuda.is_available():
        # PyTorch MPS can fail with huge MoE buffers on Apple Silicon; CPU loading is slower but avoids that backend limit.
        device_map = {"": "cpu"}

    tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_id,
        dtype=torch.bfloat16,
        device_map=device_map,
        offload_folder=str(offload_folder),
        trust_remote_code=True,
    )
    model.eval()

    messages: list[dict[str, Any]] = [{"role": "user", "content": prompt}]
    inputs = tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        return_tensors="pt",
        return_dict=True,
    ).to(model.device)

    # Hy-MT2's model card recommends 4096 generated tokens for translation.
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=4096,
            temperature=0.7,
            top_p=1.0 if "30B-A3B" in model_id else 0.6,
            repetition_penalty=1.0 if "30B-A3B" in model_id else 1.05,
        )

    generated = outputs[0][inputs["input_ids"].shape[-1] :]
    return tokenizer.decode(generated, skip_special_tokens=True).strip()


def make_prompt(text: str, target_language: str) -> str:
    return (
        f"Auto -> {target_language}\n"
        "Preserve paragraph breaks and line breaks.\n\n"
        "Text:\n"
        "<<<\n"
        f"{text}\n"
        ">>>\n\n"
        "Translation:"
    )


def clean_translation(text: str) -> str:
    cleaned = text.strip()
    for instruction in LEAKED_PROMPT_INSTRUCTIONS:
        cleaned = cleaned.replace(instruction, "")
    lines = [
        line
        for line in cleaned.splitlines()
        if line.strip().lower() not in LEAKED_PROMPT_INSTRUCTION_LINES
    ]
    cleaned = "\n".join(lines).strip()
    for label in ("Translation:", "Translated text:", "Translated result:", "Result:"):
        if cleaned.lower().startswith(label.lower()):
            remainder = cleaned[len(label) :].strip()
            if remainder:
                return remainder
    return cleaned


LEAKED_PROMPT_INSTRUCTIONS = [
    "Note that you should only output the translated result without any additional explanation:",
    "Note that you should only output the translated result without any additional explanation.",
    "Only output the translated result without any additional explanation:",
    "Only output the translated result without any additional explanation.",
]
LEAKED_PROMPT_INSTRUCTION_LINES = {value.strip().lower() for value in LEAKED_PROMPT_INSTRUCTIONS}


if __name__ == "__main__":
    raise SystemExit(main())
