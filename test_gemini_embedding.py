"""
Standalone test for useGeminiEmbedding — run BEFORE the full OmegaClaw loop.
"""
import os
import sys

if "GEMINI_API_KEY" not in os.environ:
    print("ERROR: GEMINI_API_KEY is not set.")
    sys.exit(1)

import lib_llm_ext

try:
    vector = lib_llm_ext.useGeminiEmbedding("Council test embedding")
    print(f"SUCCESS: got a vector of length {len(vector)}")
    print(f"First 5 values: {vector[:5]}")
except Exception as e:
    print(f"FAILED: {e}")
    sys.exit(1)