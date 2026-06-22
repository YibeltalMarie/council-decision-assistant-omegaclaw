"""
Standalone test for GeminiProvider — run this BEFORE attempting the full
OmegaClaw loop, to confirm the Gemini integration works in isolation.
"""
import os
import sys

# Sanity check: make sure the API key is actually set before we even try
if "GEMINI_API_KEY" not in os.environ:
    print("ERROR: GEMINI_API_KEY is not set in your environment.")
    print('Run: export GEMINI_API_KEY="your-real-key-here"')
    sys.exit(1)

import lib_llm_ext

print("Checking if Gemini provider is available...")
provider = lib_llm_ext._get_provider("Gemini")

if provider is None:
    print("ERROR: 'Gemini' provider not found in registry.")
    print("Check that GeminiProvider was registered in lib_llm_ext.py.")
    sys.exit(1)

if not provider.is_available:
    print("ERROR: Gemini provider exists but is_available is False.")
    print("This usually means GEMINI_API_KEY isn't visible to this script.")
    sys.exit(1)

print("Provider found and available. Sending a real test message...")

try:
    response = lib_llm_ext.callProvider(
        "Gemini",
        "You are a helpful assistant. :-:-:-: Say 'Council test successful' and nothing else.",
        max_tokens=100,
        reasoning="medium",
    )
    print("\n--- RAW RESPONSE FROM GEMINI ---")
    print(response)
    print("--- END RESPONSE ---\n")

    if response.strip():
        print("SUCCESS: Gemini responded. The integration works.")
    else:
        print("WARNING: Got an empty response. Check the [LLM_RAW] log line above for clues.")

except Exception as e:
    print(f"FAILED: {e}")
    sys.exit(1)