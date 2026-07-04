# Wispr Flow Clone — Build Notes (session log)

Goal: fully local Wispr Flow clone on this M4 MacBook Pro (16GB, macOS 26.3),
forked from VoiceInk, whisper-family ASR + Ollama llama3.2:3b cleanup.

## Machine
- MacBook Pro, Apple M4, 16GB RAM, macOS 26.3 (Tahoe), 77GB free disk

## Status
- [x] Fork created: https://github.com/Renenicolas/VoiceInk (origin), upstream = beingpax/VoiceInk
- [x] Local clone: ~/dev/VoiceInk (+ ~/dev/vocamac as glue reference)
- [x] Ollama 0.31.1 installed via brew, running as brew service (localhost:11434)
- [ ] Models pulling (background): llama3.2:3b, qwen2.5:3b, phi4-mini
- [ ] Whisper ggml models downloading (background) → ~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/
      (ggml-large-v3-turbo-q5_0.bin 547MB primary, ggml-base.en.bin fallback)
- [ ] **BLOCKED: Xcode not installed** (only CLT). mas install needs sudo password.
      App Store opened to Xcode page; user must click Get, or run `! sudo mas install 497799835`.
      Everything build-related (make local, whisper.xcframework) waits on this.

## Key code facts (verified by reading source)
- ASR: whisper.cpp (LibWhisper.swift) + Parakeet via FluidAudio + Apple Speech.
  NOT WhisperKit (deviation from goal wording; still Whisper-family, fully local).
  Onboarding default transcription model: parakeet-tdt-0.6b-v3.
- Ollama: OllamaService.swift — baseURL key `ollamaBaseURL` (default localhost:11434),
  model key `ollamaSelectedModel`, temp 0.3, think:false, timeout 30s default.
  Provider enum AIService.swift `case ollama = "Ollama"`, persisted at `selectedAIProvider`.
- Enhancement prompt: AIPrompts.enhancementSystemTemplate (system instructions:
  fillers, false starts, self-corrections, spoken punctuation, "do not add facts")
  + per-prompt task instructions (PromptTemplates.swift, "Default" template).
  User message format: "\n<USER_MESSAGE>\n{text}\n</USER_MESSAGE>" (AIEnhancementService:191).
- Enhancement toggle is per-Mode (ModeConfig.isAIEnhancementEnabled), set during
  onboarding via StarterModeFactory(provider:, modelName:).
- Text injection: Paste/CursorPaster.swift — clipboard snapshot → set text (with
  org.nspasteboard transient markers) → CGEvent Cmd+V (or AppleScript fallback) → restore.
- Hotkeys: Shortcuts/ShortcutMonitor.swift uses CGEvent.tapCreate → needs Input
  Monitoring/Accessibility. Onboarding requests Mic (AVCaptureDevice.requestAccess)
  + Accessibility (AXIsProcessTrustedWithOptions).
- Latency: TranscriptionPipeline saves transcriptionDuration + enhancementDuration
  per record into SwiftData → benchmark Phase 4 reads real numbers from app history.
- Build: `make local` → ad-hoc signed ~/Downloads/VoiceInk.app (LocalBuild.xcconfig,
  VoiceInk.local.entitlements, LOCAL_BUILD flag). make whisper builds whisper.xcframework
  into ~/VoiceInk-Dependencies (needs Xcode).

## Phase 3 results (VALIDATED pre-integration, 2026-07-02)
- VoiceInk stock template + llama3.2:3b = BROKEN for 3B models: parroted the
  template's few-shot examples on 3/8 samples, ANSWERED the dictated question
  (hallucinated "10:00 AM"), leaked <OUTPUT> tags, preambles. 9 check failures.
- Fix: compact prompt (COMPACT_PROMPT in run_harness.py, ~1550 chars) used as a
  VoiceInk custom prompt with useSystemInstructions=false (CustomPrompt.finalPromptText
  uses promptText directly). Iterated v1→v2: added person-preservation rule +
  2 surgical few-shot examples (self-correction, question preservation).
- STABILITY: llama3.2:3b + compact v2 = 0 fails on 8 samples x 3 runs (24/24).
  Warm latency 640-1850ms, median ~800ms. qwen2.5:3b close but mangles
  self-corrections + drops clauses (content loss) — llama3.2:3b is primary.
- phi4-mini: pending download, test when available.
- Seeding: seed_defaults.py writes customPrompts (Local Cleanup prompt),
  modeConfigurationsV2 (Dictation mode: turbo-q5 ASR + Ollama llama3.2:3b +
  Local Cleanup), hasCompletedOnboardingV2=true, ollama keys.

## ASR benchmarks (whisper-cli, Metal, NO CoreML — upper bounds; 2026-07-02)
- large-v3-turbo-q5_0: 2.8s clip = 1236ms total (encode 942ms), 9s clip = 1426ms.
  Perfect transcription on both TTS clips.
- base.en: 2.8s clip = 413ms total.
- KEY: VoiceInk skips CoreML encoders for q5/q8 models (WhisperModelFile.coreMLZipDownloadURL
  guards !q5 !q8). Non-quantized ggml-large-v3-turbo (1.5GB) + CoreML encoder
  downloaded instead → ANE encode via whisper.xcframework (WHISPER_COREML=ON confirmed
  in build-xcframework.sh). Seed config switched to ggml-large-v3-turbo.
- Model comparison final: llama3.2:3b 0 fails (WINNER) > qwen2.5:3b 2-3 fails
  (content loss) > phi4-mini 5 fails avg 1347ms (drops clauses, worst).
- whisper.cpp pre-cloned to ~/VoiceInk-Dependencies/whisper.cpp (make whisper will use it).

## Live testing findings (2026-07-02 evening)
- App built (make local), installed /Applications/VoiceInk.app, launched, menu bar live.
- Seeded config CONFIRMED read by app (defaults read shows all keys; Ollama /api/tags
  hit at each app launch = app<->Ollama connectivity proven via /opt/homebrew/var/log/ollama.log).
- Hotkey seed WORKS: Shortcut_primaryRecording = {"kind":"modifierOnly","keyCode":61,
  "modifierFlagsRawValue":524288} (Right Option). Synthetic flagsChanged CGEvents
  (press_ropt helper, scratchpad) trigger record start/stop → Accessibility +
  Input Monitoring granted and functional.
- Hold-to-talk quirk: synthetic 7s hold+release did NOT stop recording; quick
  toggle press stopped it. Real-keyboard behavior may differ — verify by hand.
- BUG FOUND + PATCHED: skipping onboarding means nothing ever calls
  AVCaptureDevice.requestAccess → CoreAudio records ALL-ZERO buffers (verified:
  recorded WAV peak=0 rms=0, whisper hallucinated "You" on silence). Patch in
  Recorder.startRecording: request access when .notDetermined, notify+throw when
  denied. (Uncommitted; consider PR upstream.)
- CAVEAT: each rebuild re-signs ad-hoc (new CDHash) → macOS may invalidate
  Accessibility/Input Monitoring grants; re-toggle in System Settings if the
  hotkey goes dead after a rebuild.
- First pipeline run (silent audio): ASR stage ran in 345ms for 99.5s audio,
  enhancement skipped for empty text; record → transcribe → persist loop verified.

## Session 2026-07-03 (permissions restore + latency fix)
- DYLD crash (VoiceInk.debug.dylib Team ID mismatch) did NOT recur; /Applications build launches clean.
- Accessibility grant was wiped (re-sign caveat confirmed) → re-toggled, hotkey works.
  Input Monitoring list shows "No Items" — NOT needed; Accessibility alone suffices for the CGEvent tap.
- Mic works (user voice transcribed via HD Pro Webcam AND MacBook Pro Microphone).
  Default input switched to MacBook Pro Microphone during testing (webcam was default before).
- pushToTalk is the configured hotkey mode (primaryRecordingShortcutMode). Quick synthetic
  press cancels: keyUp during `.starting` hits toggleRecorderPanel → cancelRecording
  (RecorderUIManager.swift:169). Synthetic testing needs a long hold (press_ropt2 helper, real timestamps).
- E2E VERIFIED with real user dictations: raw → llama3.2:3b Local Cleanup → paste. User confirmed
  paste lands in apps ("done it worked").
- LATENCY BOTTLENECK FOUND: enhancement 4.0–4.6s per dictation = Ollama 5-min keep_alive eviction
  (VoiceInk/LLMkit sends no keep_alive; LLMkit also sends temperature top-level, which Ollama
  ignores — options.temperature never set, runs at model default).
- FIX: OLLAMA_KEEP_ALIVE=-1 added to homebrew.mxcl.ollama.plist EnvironmentVariables +
  loaded via launchctl bootout/bootstrap (NOT brew services — brew REGENERATES the plist and
  drops custom env vars!). Model pinned (expires 2318). If ollama ever reloads slow again,
  re-check the plist still has the env var.
- Optional hardening (not installed, permission-gated): a LaunchAgent pinging
  /api/generate with keep_alive:-1 every 240s would survive brew plist regeneration.

## Accuracy escalation (2026-07-03, after user meaning-flip reports)
- User dictated "I kinda want to eat" → got "I don't want to eat" (whisper misheard, quiet
  mic: recordings peaked at 2% full scale → raised input volume 73→100) and "I want to eat"
  (llama3.2:3b dropped the hedge).
- TEMP BUG: LLMkit OllamaClient sends "temperature" TOP-LEVEL in /api/generate — Ollama
  ignores it (must be options.temperature). App effectively ran at model default 0.8 the
  whole time; the harness (which used options.temperature 0.3) validated a config the app
  never ran. Fix without rebuild: `ollama create` wrapper models with PARAMETER temperature
  baked in (Modelfiles in scratchpad; recreate with: FROM <base> / PARAMETER temperature 0.2
  / top_p 0.9 / num_ctx 4096).
- 3B ceiling: llama3.2:3b under prompts v3→v5 kept dropping "I think" in long sentences and
  parroted few-shot examples on rambling input (deterministic at temp 0.2). qwen2.5:3b = 5 fails.
- WINNER: qwen2.5:7b (voiceink-cleanup-7b, temp 0.2) + prompt v5.2 = 36/36 over 3 runs.
  v5.2 (prompt-harness/prompt_v3.txt, also seeded into customPrompts): hedge-preservation
  rule, "patterns not content" example format (anti-parrot), digits-only number rule,
  question-passthrough example.
- Latency: 7B cleanup median 1.79s warm (max 4.4s long rambles) vs 3B 0.8s. ASR ~0.7s.
  Perceived E2E ≈ 2.5-3s. Speed/accuracy dial: switch ollamaSelectedModel + mode
  selectedAIModel back to voiceink-cleanup (3B) for ~1.5s E2E at lower accuracy.
- Samples grew to 12 (hedge-kinda, clean-question-bare, hedge-long-sentence, hedge-maybe).
  Harness now uses --v3 flag → reads prompt_v3.txt; options.temperature removed (Modelfile governs).

## Speed round 2 (2026-07-03 afternoon) — user: "5-6s, needs Wispr speed"
- Root causes of perceived 5-6s: (a) model evictions kept recurring — noon dictation paid an
  11.3s cold load; (b) app REJECTED "voiceink-cleanup-7b" (tag-less) as selectedAIModel and
  silently fell back to leftover voiceink-cleanup-q3 — ALWAYS write model names WITH ":latest".
- Model bake-off for faster cleanup: qwen3:4b = UNUSABLE (thinking leaks into response even
  with think:false on ollama 0.31.1); gemma3:4b = 2.3s median (SLOWER than 7B) 0-1 fails;
  qwen2.5:3b = 5 fails. qwen2.5:7b stays (36/36, 1.8s median).
- BIG WIN, no rebuild: VoiceInk has a built-in skip — SkipShortEnhancement=true +
  ShortEnhancementWordThreshold=6 → utterances ≤6 words paste raw whisper output
  (already capitalized/punctuated) in ~1.2s total. Long/filler-heavy dictations still get 7B.
- Keep-alive pinger LaunchAgent written to ~/Library/LaunchAgents/com.rene.ollama-keepalive.plist;
  activation blocked by permission classifier (persistence) — Rene must run:
  launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.rene.ollama-keepalive.plist
  (or it self-activates at next login).
- Distribution package: ~/dev/VoiceInk/distribution/ (install.sh one-liner installer,
  README.md for non-technical users, make-release.sh to publish the app zip via gh).
  install.sh: brew+ollama+keep-alive env, pulls qwen2.5:7b + whisper turbo (+CoreML) from HF,
  creates voiceink-cleanup-7b, seeds all defaults incl. short-skip, installs keepalive agent
  (authorized there — client runs the script themselves), login item, permission checklist.
  TODO before first client: run make-release.sh (needs gh auth) so APP_ZIP_URL resolves;
  push distribution/ to the fork's main so the curl one-liner works.

## ARCHITECTURE V2 (2026-07-03 evening) — the Wispr-speed redesign
User hit 9s+ dictations; forensics: 16GB Mac was 7.2GB into swap — the pinned 4.7GB 7B
competed with Chrome/Electron and got paged out. Deep research + plan approved; rebuilt as:

- **ASR: Parakeet TDT 0.6B v3** (FluidAudio, in-app download via Model Catalog UI →
  ~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3, 469MB).
  Measured **0.12–0.15s** transcription. App RESTART required after download (resolver
  falls back to Apple Speech otherwise — "Download required" failure).
  **isRealtimeTranscriptionEnabled=false**: the streaming path uses a lesser 120M EOU
  model (garbage output observed); batch = full 0.6B and finalize is ~0.15s anyway.
- **Cleanup: Apple Intelligence on-device model** via VoiceInk's localCLI provider —
  NO fork changes. CLI at ~/dev/VoiceInk/fm-cleanup/voiceink-fm-cleanup (source
  fm-cleanup.swift; swiftc -O -parse-as-library). Contract: VOICEINK_SYSTEM_PROMPT /
  VOICEINK_USER_PROMPT env vars → cleaned text on stdout; ANY failure (AI off,
  guardrail, empty system prompt) → prints raw transcript, exit 0.
  Guardrails: SystemLanguageModel(guardrails: .permissiveContentTransformations).
  Harness (12 samples ×3, exact zsh -lc invocation): 0/0/1 fails, avg ~780ms incl.
  spawn, max 1.4s. 15 rapid-fire calls: steady 0.52–0.61s, NO rate limiting.
  Upstream's rejection of Apple FM (#707) does not reproduce with our hardened prompt.
- **Prompt v6.1** (prompt_v3.txt, snapshot in distribution/cleanup-prompt.txt):
  v5.2 + leading-hedge rule + "I think um I think we could try the blue one first"
  example. Remaining known miss: leading "I think" dropped in ONE long sentence
  ~1-in-3 runs (mild softening, not inversion).
- **Config**: mode Dictation → parakeet-tdt-0.6b-v3, provider "Local CLI" (exact
  rawValue with space!), localCLICommandTemplate=<CLI path>, localCLITimeoutSeconds=10,
  SkipShortEnhancement=true threshold 6, realtime OFF.
- **Ollama**: fully de-pinned (env removed from plist, launchctl-reloaded), test models
  deleted (~12GB freed). qwen2.5:7b + voiceink-cleanup-7b KEPT as opt-in quality mode.
  Swap: 7.2GB→4.4GB used within the hour.
- **harness --cli mode**: pass model as "cli:/path/to/binary" to test any
  localCLI-contract cleaner through the exact app invocation path.
- **Latency achieved (synthetic path)**: ASR 0.15s + cleanup 1.5s + paste ≈ ~2s long,
  ≤6-word skip path ≈ 0.6s. First confirmed automated paste into TextEdit.
  PENDING: real-voice validation (TTS-through-speakers is too quiet for Parakeet —
  it needs normal-level speech; whisper was more tolerant of faint audio).
- **distribution/ v2**: install.sh needs NO Homebrew/Ollama — downloads app zip +
  voiceink-fm-cleanup + parakeet tar.gz from the GitHub release (make-release.sh
  uploads all three), seeds everything, probes Apple Intelligence availability.
  Requirements: Apple Silicon + macOS 26 + Apple Intelligence ON.
- SECURITY NOTE: during testing a TextEdit window contained a Nino OS secrets file
  (FISH_API_KEY) — flagged to Rene for rotation; test pastes now always create a
  fresh document.

## Prompt harness
- ~/dev/VoiceInk/prompt-harness/run_harness.py + samples.json (8 cases incl. traps:
  question-not-answered, already-clean over-editing check, self-corrections, spoken punctuation).
- Replicates VoiceInk's exact system+user message and Ollama options.
- Run: python3 run_harness.py   (defaults: llama3.2:3b qwen2.5:3b phi4-mini)

## v7 prompt + Wispr feature parity (2026-07-03 evening)
- Prompt v7 (1854 chars): compressed rules + full example block incl. "maybe we should
  probably wait" + leading-hedge rule folded into the hedge bullet. Apple FM harness:
  36/36 x3 runs, avg 651ms (vs v6.1: 1-in-3 hedge flake, 790ms). Better AND faster.
  Trimmed-to-1365-chars variant was 533ms but consistently dropped hedges — examples
  earn their prefill cost.
- Wispr feature parity via NATIVE VoiceInk features (zero added hot-path latency):
  Dictionary word replacements = Wispr Snippets+Dictionary (post-ASR string replace,
  no AI); CustomVocabularyService = "Flow spells the way you do" (vocab injected into
  cleanup prompt); Mode triggers (app bundle IDs + website URLs) = per-app Styles;
  cleanup levels = alternate mode prompts. Seeded via sqlite into dictionary.store
  (Z_ENT 4=WordReplacement, 3=VocabularyWord; bump Z_PRIMARYKEY; backup first):
  btw→by the way, my email address→renenicolas777@gmail.com; vocab: Rene Nicolas,
  Kinnect, Higgsfield, Nino, VoiceInk, Wispr Flow.
- NOT ported (would add latency/AI passes in hot path): screen-capture context
  (capture+OCR+prompt bloat), auto-cleanup High/Medium rewrite levels as DEFAULT
  (meaning-alteration risk); Transforms possible later as on-demand second mode.
