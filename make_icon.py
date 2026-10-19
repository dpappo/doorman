#!/usr/bin/env python3
"""Generates app icon options for Doorman with an OpenRouter image model.

Reads the API key from openrouter-key.txt (never prints it), asks the model for
square artwork, then shapes each result into a macOS-style rounded-square icon
(1024x1024 canvas with transparent margins, like Apple's icon grid).

Usage: python3 make_icon.py [model] [count]
"""
import base64, io, json, os, sys, urllib.request, urllib.error
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "icon-options")
MODEL = sys.argv[1] if len(sys.argv) > 1 else "openai/gpt-image-2.5-sunburst"
COUNT = int(sys.argv[2]) if len(sys.argv) > 2 else 3

PROMPTS = [
    "App icon artwork for a Mac app called Doorman, which pops up a live video of your front door. "
    "Show a sleek modern video doorbell (a tall rounded pill shape with a small round camera lens at the top "
    "and a glowing ring-shaped button below), seen straight on, centered. Background: a warm, rich gradient "
    "like a front door at dusk (deep teal to navy). Soft studio lighting, subtle glassy depth, clean and "
    "minimal, in the polished style of Apple's macOS app icons. Fill the entire square edge to edge. "
    "No text, no letters, no border, no rounded corners, no drop shadow around the edges.",

    "App icon artwork for a Mac app that shows a small floating picture-in-picture video of your front door "
    "when someone rings. Concept: a simple front door shape with a little glowing video window floating in "
    "front of it, and a small doorbell button. Flat-but-dimensional modern style with soft gradients, "
    "warm amber light against a deep blue background, like Apple's macOS icons. Centered composition with "
    "generous padding inside the artwork. Fill the entire square edge to edge. No text, no letters, "
    "no border, no rounded corners.",

    "App icon artwork: a single elegant doorbell button, round, with a softly glowing white ring of light, "
    "mounted on a matte dark-slate plate, viewed straight on and centered. A tiny camera lens dot above the "
    "button. Premium, minimal, tactile, in the style of Apple's macOS app icons, gentle highlights and "
    "shadows. Background gradient from charcoal to deep indigo. Fill the entire square edge to edge. "
    "No text, no letters, no border, no rounded corners.",
]


def read_key():
    with open(os.path.join(HERE, "openrouter-key.txt")) as f:
        key = f.read().strip()
    if not key or "PASTE-YOUR" in key:
        sys.exit("No API key yet: openrouter-key.txt still has the placeholder.")
    return key


def post(key, url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                 "HTTP-Referer": "https://localhost/doorbell-pip", "X-Title": "Doorman"})
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError(f"HTTP {e.code}: {detail}")


def image_bytes(item):
    if not isinstance(item, dict):
        return None
    if item.get("b64_json"):
        return base64.b64decode(item["b64_json"])
    url = item.get("url") or (item.get("image_url") or {}).get("url", "")
    if url.startswith("data:"):
        return base64.b64decode(url.split(",", 1)[1])
    if url.startswith("http"):
        with urllib.request.urlopen(url, timeout=120) as r:
            return r.read()
    return None


def generate(key, prompt):
    # Dedicated image models use the images endpoint (OpenAI-style request/response).
    last_error = None
    for path in ("/api/v1/images/generations", "/api/v1/images"):
        try:
            data = post(key, "https://openrouter.ai" + path,
                        {"model": MODEL, "prompt": prompt, "n": 1, "size": "1024x1024"})
        except RuntimeError as e:
            last_error = e
            if "HTTP 404" in str(e) or "HTTP 405" in str(e):
                continue
            raise
        for item in data.get("data") or data.get("images") or []:
            raw = image_bytes(item)
            if raw:
                return raw
        raise RuntimeError("No image in response: " + json.dumps(
            {k: (v if k != "data" else "...") for k, v in data.items()})[:400])
    if "cannot be used with the chat" not in str(last_error):
        pass
    # Chat-style image models (e.g. gpt-5.4-image-2) fall back to chat/completions.
    return generate_chat(key, prompt)


def generate_chat(key, prompt):
    body = json.dumps({
        "model": MODEL,
        "modalities": ["image", "text"],
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions", data=body,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                 "HTTP-Referer": "https://localhost/doorbell-pip", "X-Title": "Doorman"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError(f"HTTP {e.code}: {detail}")
    msg = (data.get("choices") or [{}])[0].get("message", {})
    for img in msg.get("images") or []:
        url = (img.get("image_url") or {}).get("url", "")
        if url.startswith("data:"):
            return base64.b64decode(url.split(",", 1)[1])
    raise RuntimeError("No image in response: " + json.dumps(data)[:400])


def squircle_mask(size, radius_ratio=0.225):
    # Rounded square close to Apple's icon shape (supersampled for smooth edges).
    s = size * 4
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * radius_ratio), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def shape_icon(raw):
    art = Image.open(io.BytesIO(raw)).convert("RGBA")
    w, h = art.size
    side = min(w, h)
    art = art.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2))
    body = 824                              # Apple grid: 824px body on a 1024px canvas
    art = art.resize((body, body), Image.LANCZOS)
    art.putalpha(squircle_mask(body))
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    sm = Image.new("L", (1024, 1024), 0)
    sm.paste(squircle_mask(body), (100, 112))
    shadow.putalpha(sm.point(lambda v: int(v * 0.35)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(art, (100, 100))
    return canvas


def main():
    key = read_key()
    os.makedirs(OUT, exist_ok=True)
    made = []
    for i, prompt in enumerate(PROMPTS[:COUNT], 1):
        try:
            raw = generate(key, prompt)
        except Exception as e:
            print(f"option {i}: FAILED {e}")
            continue
        with open(os.path.join(OUT, f"raw-{i}.png"), "wb") as f:
            f.write(raw)
        shape_icon(raw).save(os.path.join(OUT, f"option-{i}.png"))
        made.append(i)
        print(f"option {i}: ok")
    print("MADE", made, "MODEL", MODEL)


if __name__ == "__main__":
    main()
