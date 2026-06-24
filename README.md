# Council — Evidence-Weighted Decision Assistant on OmegaClaw

> An OmegaClaw-based agent that helps you make better decisions by gathering 
> real evidence, weighing it with auditable NAL/PLN confidence scores instead 
> of guesswork, and remembering whether its past recommendations were right — 
> so its advice gets sharper over time.

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [The Problem Council Solves](#the-problem-council-solves)
3. [Architecture](#architecture)
4. [What Was Built](#what-was-built)
5. [Skills Implemented](#skills-implemented)
6. [Key Engineering Decisions](#key-engineering-decisions)
7. [Setup and Installation](#setup-and-installation)
8. [Running Council](#running-council)
9. [Demo Walkthrough](#demo-walkthrough)
10. [Task Answers](#task-answers)
11. [Bonuses Achieved](#bonuses-achieved)
12. [Known Limitations and Future Work](#known-limitations-and-future-work)

---

## Project Overview

**Council** is built on top of OmegaClaw — SingularityNET's goal-autonomous 
agent framework that combines LLM reasoning with formal logic engines (NAL/PLN) 
and persistent structured memory (AtomSpace/ChromaDB).

Most AI decision tools just ask an LLM and return a confident-sounding answer. 
Council forces every recommendation through a transparent evidence pipeline:
gather real web evidence → score each source by reliability → combine scores 
using NAL's Truth_Revision formula → compare options using Truth_Comparison → 
store the decision in long-term memory for future calibration.

The result is a recommendation with an auditable confidence number — not a 
guess dressed up as certainty.

---

## The Problem Council Solves

People and organizations make consequential decisions based on whoever or 
whatever sounds most confident. LLMs amplify this problem — they produce 
fluent, authoritative-sounding answers regardless of actual evidence quality.

OmegaClaw was specifically designed to address this: its NAL/PLN engines 
produce real, mathematically-grounded confidence numbers rather than LLM 
gut feelings. Council makes this the entire product — every recommendation 
comes with a confidence score derived from real evidence, not the model's 
internal biases.

**Example interaction:**
User: can you compare Spring_Boot and PHP for my next project?
Council: I am analyzing Spring Boot and PHP. One moment.
Council: Analysis complete. Spring Boot: stv(0.8, 0.7).

PHP: stv(0.6, 0.6). Spring Boot is recommended for

enterprise/high-performance contexts. PHP remains

superior for rapid deployment and content-heavy sites.


---

## Architecture

Council runs on a 3-layer stack:

┌─────────────────────────────────────────────┐

│           OmegaClaw-Core (MeTTa)            │

│   loop.metta → skills.metta → memory.metta  │

│   channels.metta → lib_nal.metta            │

├─────────────────────────────────────────────┤

│         PeTTa (MeTTa Interpreter)           │

│         Written in SWI-Prolog               │

├─────────────────────────────────────────────┤

│      petta_lib_chromadb (Memory Plugin)     │

│      ChromaDB + Gemini Embeddings           │

└─────────────────────────────────────────────┘

### The 8-Step Agent Loop

Every iteration runs this cycle, continuously:
1. receive()        → pull latest message from IRC or Telegram
2. getContext()     → build prompt: system + skills + history +
 last results + time
3. LLM call         → Gemini reads everything, decides what to do
4. parse response   → sread() converts LLM text to MeTTa expressions
5. eval each skill  → actually execute the chosen skill(s)
6. addToHistory     → save what happened to history.metta
7. sleep            → wait sleepInterval seconds
8. recurse          → repeat from step 1

### How State Persists Across Iterations

State lives in three tiers with deliberately different lifespans:

| Tier | Mechanism | Lifespan | Council Use |
|---|---|---|---|
| Short-term | `pin` | Current iteration only | Task progress tracking |
| Long-term | `remember/query` (ChromaDB) | Forever, survives restarts | `record_decision` storage |
| Episodic | `history.metta` | Disk file, rolling window | Conversation continuity |

`&lastresults` carries each iteration's skill output into the next prompt — 
this is how Council's multi-step pipeline works across iterations without 
explicit passing.

---

## What Was Built

### 1. GeminiProvider — Native Gemini Integration

The default OmegaClaw providers are Anthropic, OpenAI, and ASIOne. 
Gemini was not supported. A full `GeminiProvider` class was built from 
scratch in `lib_llm_ext.py` following the existing `AbstractAIProvider` 
pattern:

```python
class GeminiProvider(AbstractAIProvider):
    """Provider for Google's Gemini models using the native google-genai SDK."""
    
    def chat(self, content, max_tokens=6000, reasoning="medium", **kwargs):
        # splits system/user on ":-:-:-:" separator
        # uses GenerateContentConfig for system_instruction + max_output_tokens
        # returns clean text response
```

**Why native SDK instead of the OpenAI-compatible shim:** Using 
`google-genai` directly gives access to Gemini-specific features 
(system_instruction as a first-class field, native config objects) 
rather than mapping everything through OpenAI's interface. It also 
produces cleaner, more maintainable code.

**Model selection:** Before writing any code, the real list of available 
models was queried via `client.models.list()` to avoid using deprecated 
model strings. `gemini-3.5-flash` was selected as the confirmed-available 
GA model for chat.

**Registration:**
```python
_register_provider_instance(GeminiProvider(
    name="Gemini", 
    var_name="GEMINI_API_KEY", 
    model_name="gemini-3.5-flash"
))
```

**Config change in loop.metta:**
```metta
(configure provider Gemini)
(configure LLM gemini-3.5-flash)
```

### 2. Gemini Embedding Provider

OmegaClaw's default embedding provider downloads a local model from 
HuggingFace (~500MB). On constrained hardware and limited internet, this 
was impractical. A `useGeminiEmbedding` function was built using 
`gemini-embedding-001` — Gemini's free-tier embedding model — eliminating 
the local download entirely:

```python
def useGeminiEmbedding(atom):
    response = _gemini_embedding_client.models.embed_content(
        model="gemini-embedding-001",
        contents=atom,
    )
    return response.embeddings[0].values  # 3072-dimensional vector
```

**Config change in memory.metta:**
```metta
(configure embeddingprovider Gemini)
```

The embed() dispatch in memory.metta was extended to handle the new 
Gemini branch:
```metta
(= (embed $str)
   (if (== (embeddingprovider) Local)
       (py-call (lib_llm_ext.useLocalEmbedding (string-safe $str)))
       (if (== (embeddingprovider) Gemini)
           (py-call (lib_llm_ext.useGeminiEmbedding (string-safe $str)))
           (useGPTEmbedding (string-safe $str)))))
```

### 3. OUTPUT_FORMAT Extension — Multi-Argument Skills

A key architectural limitation was discovered during development: 
OmegaClaw's OUTPUT_FORMAT only supported single-argument skill calls. 
The parser (`sread`) merged everything after the skill name into one 
quoted string, making `compare_options Spring_Boot PHP` arrive as 
`(compare_options "Spring_Boot PHP")` — one argument instead of two.

**Root cause:** The LLM outputs plain text like `toolName arg1 arg2`, 
which `sread` wraps into a single string. The fix required teaching the 
LLM to output proper MeTTa s-expressions with each argument quoted 
separately: `(toolName "arg1" "arg2")`.

**Fix in loop.metta getContext():**
```metta
" OUTPUT_FORMAT: Up to 5 lines. Single-arg: toolName arg. 
  Multi-arg MUST use s-expression with each arg quoted: 
  (toolName _quote_arg1_quote_ _quote_arg2_quote_). 
  Do not use variables:" (newline)
" toolName1 arg1" (newline)
" (toolName2 _quote_arg1_quote_ _quote_arg2_quote_)" (newline)
" (toolName3 _quote_arg1_quote_ _quote_arg2_quote_ 
             _quote_arg3_quote_ _quote_arg4_quote_)" (newline)
" toolName4 arg1" (newline)
" toolName5 arg1" (newline)
```

This change maintains full backward compatibility — all existing 
single-argument skills continue working unchanged, while new multi-argument 
skills now parse correctly.

### 4. Security Policy Fix

OmegaClaw uses Landlock (Linux kernel sandboxing) to restrict filesystem 
access. The `chroma_db/` folder at the PeTTa root was missing from the 
`read_write` whitelist in `profile/policy.yaml`, causing ChromaDB to fail 
with "attempt to write a readonly database." The fix:

```yaml
read_write:
  - /path/to/PeTTa/repos/OmegaClaw-Core/memory
  - /path/to/PeTTa/chroma_db   # added
  - /tmp
```

---

## Skills Implemented

### evidence_search

Searches the web for real evidence about a specific option using 
DuckDuckGo (DDGS). Returns results with full URLs, titles, and snippets 
for source-tier classification.

```metta
"- Search the web for evidence about a specific option, 
   for decision-making: evidence_search option_name"

(= (evidence_search $option)
   (py-call (lib_llm_ext.search_with_urls 
            (py-str ("Reliable evidence pros and cons about: " $option)))))
```

The `search_with_urls` Python function formats results as:


(TITLE: ... URL: https://... SNIPPET: ...)

Including the full URL is critical — the LLM uses the domain to assign 
confidence tiers (official docs vs stackoverflow vs blog) rather than 
guessing from title text alone.

### compare_options

The public entry point — accepts two options, orchestrates the full 
pipeline internally.

```metta
"- Compare two options using evidence search and NAL reasoning. 
   MUST use s-expression with each arg quoted separately. 
   Example: (compare_options _quote_Spring_Boot_quote_ _quote_PHP_quote_): 
   compare_options option_a option_b"

(= (compare_options $option_a $option_b)
   (let* (($ev_a (evidence_search $option_a))
          ($ev_b (evidence_search $option_b))
          ($verdict (weigh_evidence $option_a $ev_a $option_b $ev_b)))
         (py-str ("COUNCIL DECISION: " $verdict))))
```

The user only ever calls this skill. Everything else runs internally.

### weigh_evidence

Called internally by `compare_options`. Packages the evidence with 
explicit scoring rules that instruct the LLM how to assign stv values, 
then instructs it to call NAL via metta.

```metta
(= (weigh_evidence $option_a $ev_a $option_b $ev_b)
   (py-str ("EVIDENCE_A(" $option_a "): " $ev_a
            " EVIDENCE_B(" $option_b "): " $ev_b
            " SCORING RULES by URL domain: confidence=0.9 if official 
              docs (spring.io, php.net, docs.*), 0.7 if 
              stackoverflow.com or baeldung.com, 0.4 if reddit.com, 
              medium.com, or any blog/forum."
            " frequency=0.8 if mostly positive, 0.3 if mostly negative, 
              0.55 if neutral."
            " Run metta (Truth_Revision (stv f1 c1) (stv f2 c2)) per 
              option, then metta (Truth_Comparison (stv fa ca) (stv fb cb)), 
              then send winner with scores.")))
```

**Why confidence tiers are rule-constrained rather than code-enforced:**
The LLM assigns initial stv values following explicit URL-domain rules 
embedded in the instruction string. The NAL math combining those values 
(`Truth_Revision`, `Truth_Comparison`) is fully deterministic and 
auditable. This is an honest design — the rules constrain the LLM's 
scoring, while NAL verifies the arithmetic.

### record_decision

Writes the final recommendation into ChromaDB long-term memory with a 
timestamp, making it retrievable in future sessions via semantic search.

```metta
"- Record a final decision and its reasoning to long-term memory: 
   record_decision decision_summary"

(= (record_decision $summary)
   (remember (py-str ("COUNCIL_DECISION: " $summary 
                      " | TIME: " (get_time_as_string)))))
```

**Confirmed working:** A decision stored in one session was successfully 
retrieved in a later session via `query "past decisions"`, demonstrating 
real cross-session memory — the foundation of Council's self-calibration 
capability.

---

## Key Engineering Decisions

### Why Gemini over other providers

Gemini was chosen because both the chat API (`gemini-3.5-flash`) and 
embedding API (`gemini-embedding-001`) are available on the free tier — 
critical given hardware and budget constraints. The native `google-genai` 
SDK was used rather than the OpenAI-compatible shim to access Gemini's 
native features directly.

### Why search_with_urls instead of plain search

The original `evidence_search` used the existing `search` skill (DuckDuckGo 
via DDGS) but returned results without URLs. Source reliability scoring 
(the core of `weigh_evidence`) requires knowing the domain — a title alone 
is ambiguous. Adding URLs gave the LLM an unambiguous, always-present 
signal for confidence tier assignment.

### Why the OUTPUT_FORMAT fix matters beyond this project

The single-argument limitation was a genuine architectural constraint 
affecting any future skill that needs structured multi-part input. The fix 
extends the system for all future developers building on OmegaClaw — not 
just Council. This is the kind of contribution the bonus criteria reward.

### Why weigh_evidence is internal-only

Making `weigh_evidence` a public skill would allow the LLM to call it 
directly without first gathering evidence — producing meaningless results. 
Marking it `[INTERNAL - called by compare_options]` in the catalogue 
guides the LLM away from direct invocation while keeping the scoring rules 
visible for when it processes the results.

---

## Setup and Installation

### Prerequisites

- Git
- Python 3.12+
- SWI-Prolog 9.1.12+
- A Gemini API key (free tier at https://aistudio.google.com/apikey)
- A Telegram bot token (from @BotFather)

### Installation

```bash
# Clone PeTTa (the MeTTa interpreter)
git clone https://github.com/trueagi-io/PeTTa
cd PeTTa

# Clone dependencies
mkdir -p repos
git clone https://github.com/YourUsername/council-decision-assistant-omegaclaw.git repos/OmegaClaw-Core
git clone https://github.com/patham9/petta_lib_chromadb.git repos/petta_lib_chromadb
cp repos/OmegaClaw-Core/run.metta ./

# Create and activate virtual environment
python3 -m venv ./.venv
source ./.venv/bin/activate

# Install PyTorch (CPU-only)
python3 -m pip install --index-url https://download.pytorch.org/whl/cpu torch

# Install dependencies
python3 -m pip install -r ./repos/OmegaClaw-Core/requirements.txt

# Install Gemini SDK
pip install google-genai
```

### Verify Gemini Integration

```bash
cd repos/OmegaClaw-Core
export GEMINI_API_KEY="your-key-here"
python3 test_gemini.py
# Expected: SUCCESS: Gemini responded.

python3 test_gemini_embedding.py
# Expected: SUCCESS: got a vector of length 3072
```

---

## Running Council

### IRC mode

```bash
cd /path/to/PeTTa
export GEMINI_API_KEY="your-key-here"
sh run.sh run.metta IRC_channel="#your-channel"
```

Then join https://webchat.quakenet.org/ and connect to the same channel.

### Telegram mode

```bash
cd /path/to/PeTTa
export GEMINI_API_KEY="your-key-here"
export TG_BOT_TOKEN="your-bot-token"
sh run.sh run.metta commchannel=telegram
```

Then open your bot in Telegram and start chatting.

### Important notes

- `sleepInterval` is set to 30 seconds to conserve Gemini free-tier quota
- Clear history between test sessions to avoid context pollution:
```bash
  echo "" > repos/OmegaClaw-Core/memory/history.metta
```
- If you hit 429 quota errors, switch to a backup model in `lib_llm_ext.py`:
  `gemini-2.5-flash`, `gemini-2.0-flash`, or `gemini-flash-lite-latest`

---

## Demo Walkthrough

### 1. Basic comparison (IRC or Telegram)
You:     can you compare Spring_Boot and PHP for my next project?
Council: I am analyzing Spring Boot and PHP. I will provide the

comparison shortly.
Council: Analysis complete: Spring Boot (Confidence 0.8, Positive)
outperforms PHP (Confidence 0.6, Neutral/Mixed) for
enterprise-grade, scalable microservices. PHP remains
superior for rapid deployment and content-heavy sites.

### 2. What happens invisibly between those two messages
Iteration 2:

compare_options("Spring_Boot", "PHP") called

→ evidence_search("Spring_Boot") → 5 real web results with URLs
→ evidence_search("PHP") → 5 real web results with URLs
→ weigh_evidence returns scoring instructions
Iteration 3:

LLM reads evidence + scoring rules from LAST_SKILL_USE_RESULTS

→ assigns stv values by URL domain tier
→ calls metta (Truth_Revision ...) to combine sources
→ calls metta (Truth_Comparison ...) to compare options
→ sends final verdict to user

### 3. Recording and retrieving decisions
You:     record_decision Spring_Boot_recommended_over_PHP_confidence_0.8
Council: Decision recorded: Spring Boot recommended over PHP with

0.8 confidence.
--- restart the system ---
You:     what decisions have you made before?
Council: I have previously recorded the following decision: Spring Boot
is recommended over PHP for enterprise/high-performance contexts
with 0.8 confidence.

This demonstrates real cross-session memory — ChromaDB retrieved the 
stored decision using semantic similarity, not keyword matching.

---

## Task Answers

### Task 3 — Role of Each Major Component

| Component | Role |
|---|---|
| `loop.metta` | Runs the continuous 8-step agentic cycle. Orchestrates everything. |
| `memory.metta` | Manages 3-tier state: pin (cycle), ChromaDB (forever), history.metta (rolling log) |
| `skills.metta` | Catalogue + function definitions for all callable actions |
| `channels.metta` | IRC and Telegram I/O dispatch |
| `lib_llm_ext.py` | Python bridge to LLM providers. Extended with GeminiProvider + useGeminiEmbedding |
| `lib_nal.metta` | NAL reasoning engine: Truth_Revision, Truth_Comparison, Truth_Deduction |
| `lib_pln.metta` | PLN probabilistic reasoning engine |

### Task 4 — Agent Loop State Across Iterations

State persists through three mechanisms with different lifespans: `pin` 
(current iteration only), `remember/query` via ChromaDB (permanent, 
survives restarts, semantic search), and `history.metta` (disk-backed 
rolling episodic log injected into every prompt). `&lastresults` 
carries each iteration's skill output directly into the next prompt — 
enabling Council's multi-iteration pipeline without explicit state passing. 
Error feedback is also part of carried-forward state, enabling 
self-correction on the next turn.

### Task 5 — Design Principles Behind MeTTaClaw's Architecture

**Transparency:** Every conclusion carries auditable math — NAL's 
`Truth_Revision` and `Truth_Comparison` produce verifiable numbers, 
not LLM opinions dressed as precision.

**Simplicity:** The entire loop is ~200 lines. Council's skills average 
5-10 lines each. Everything is readable and inspectable.

**Extensibility:** Four new skills, two new provider classes, one 
OUTPUT_FORMAT extension — none touched the core loop. The multi-arg 
fix extended the system for all future developers, not just Council.

**Flexibility in memory:** Switching from Local to Gemini embeddings 
required changing one config line. The memory architecture absorbed 
the change without structural modification.

---

## Bonuses Achieved

### Bonus 2 — Custom LLM Provider (Gemini) ✅

A complete `GeminiProvider` class was implemented using Google's native 
`google-genai` SDK, following the existing `AbstractAIProvider` pattern. 
The entire Council submission — all skills, both channels, all memory 
operations — runs on Gemini. This includes:

- Chat via `gemini-3.5-flash` (confirmed available via `ListModels`)
- Embeddings via `gemini-embedding-001` (3072-dimensional vectors, 
  free tier, no local download required)

Both integrations were verified with standalone test scripts before 
being wired into the full system.

### Architectural Contribution — Multi-Argument OUTPUT_FORMAT ✅

The original OUTPUT_FORMAT supported only single-argument skill calls — 
a genuine architectural limitation for any structured multi-part skill. 
This was identified, root-caused (the `sread` parser merging unquoted 
tokens), and fixed by extending the format to support proper MeTTa 
s-expressions with quoted arguments. All existing single-argument skills 
continue working unchanged.

---

## Known Limitations and Future Work

**Context overload** — When evidence results are large (10+ results, 
long snippets), `CHARS_SENT` can reach 20,000+ characters, causing 
the LLM to retreat to querying memory instead of processing evidence. 
Fix: truncate evidence in `search_with_urls` to 3 results, 150 chars 
per snippet.

**PHP search ambiguity** — "PHP" as a search term returns medical 
results (PHP is also a medical abbreviation). Fix: more targeted query 
construction per domain type.

**GitHub evidence gathering** — Planned but deferred. Would compare 
options using the user's own repository history in addition to web 
evidence — stronger, personalized signal than generic blog posts.

**Self-calibration loop** — `record_decision` is implemented and working. 
The `record_outcome` + `recall_track_record` loop (recording whether 
past decisions turned out well, adjusting future confidence accordingly) 
was scoped as stretch and deferred due to time constraints.

**Gemini free-tier quota** — `gemini-3.5-flash` has a 20 requests/day 
limit on the free tier. Mitigated by `sleepInterval=30` and backup model 
names (`gemini-2.5-flash`, `gemini-2.0-flash`).


