#!/bin/bash
# Phase 4 benchmark: report real per-dictation latency from VoiceInk's own
# SwiftData history (populated by live dictations through the app).
# E2E (stop-speaking -> pasted) ~= transcription + enhancement + paste overhead (<100ms).
DB="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/default.store"
sqlite3 -header -column "$DB" "
SELECT
  datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime') AS at,
  printf('%.1fs', ZDURATION)                       AS audio,
  printf('%.0fms', ZTRANSCRIPTIONDURATION * 1000)  AS asr,
  printf('%.0fms', COALESCE(ZENHANCEMENTDURATION,0) * 1000) AS llm,
  printf('%.0fms', (ZTRANSCRIPTIONDURATION + COALESCE(ZENHANCEMENTDURATION,0)) * 1000) AS total,
  ZTRANSCRIPTIONMODELNAME                          AS asr_model,
  COALESCE(ZAIENHANCEMENTMODELNAME,'-')            AS llm_model,
  substr(replace(ZTEXT, char(10), ' '), 1, 40)     AS raw,
  substr(replace(COALESCE(ZENHANCEDTEXT,''), char(10), ' '), 1, 40) AS cleaned
FROM ZTRANSCRIPTION
ORDER BY ZTIMESTAMP DESC
LIMIT ${1:-10};
"
