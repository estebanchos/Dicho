#!/bin/bash
# Generates the TTS audio variants for eval fixture manifests (M12).
# Zero dependencies beyond macOS: plutil for JSON, say for TTS.
#
#   ./generate_tts.sh              # all manifests
#   ./generate_tts.sh <id> [...]   # specific fixtures
#
# Output files land in EvalFixtures/audio/tts/ (gitignored; regenerable).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p audio/tts

manifests=()
if [ "$#" -gt 0 ]; then
  for id in "$@"; do manifests+=("manifests/$id.json"); done
else
  manifests=(manifests/*.json)
fi

installed_voices=$(say -v '?')

for manifest in "${manifests[@]}"; do
  id=$(plutil -extract id raw -o - "$manifest")
  spoken=$(plutil -extract spoken raw -o - "$manifest")
  # [pause:N] markers become `say` silence markup ([[slnc ms]]).
  speakable=$(printf '%s' "$spoken" | sed -E 's/\[pause:([0-9]+)\]/[[slnc \1000]]/g')

  i=0
  while voice=$(plutil -extract "audio.tts.$i.voice" raw -o - "$manifest" 2>/dev/null); do
    file=$(plutil -extract "audio.tts.$i.file" raw -o - "$manifest")
    if ! printf '%s\n' "$installed_voices" | grep -q "^$voice "; then
      echo "SKIP $id: voice '$voice' not installed" >&2
    else
      printf '%s' "$speakable" | say -v "$voice" -o "$file" -f -
      echo "OK   $id -> $file ($voice)"
    fi
    i=$((i + 1))
  done
done
