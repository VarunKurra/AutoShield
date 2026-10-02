#!/bin/bash
# Downloads the public toxicity corpus (once) and trains Tier 1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p data build

if [ ! -f data/labeled_data.csv ]; then
  echo "› fetching corpus"
  curl -sSL -o data/labeled_data.csv \
    "https://raw.githubusercontent.com/t-davidson/hate-speech-and-offensive-language/master/data/labeled_data.csv"
fi

if [ ! -f data/wiki_toxic_balanced.csv ]; then
  echo "› fetching wiki toxic corpus"
  curl -sSL -o data/wiki_toxic_balanced.csv \
    "https://huggingface.co/datasets/OxAISH-AL-LLM/wiki_toxic/resolve/main/balanced_train.csv"
fi

python3 Tools/make_augment.py
./Tools/build.sh "${1:-release}" >/dev/null
echo "› training"
./build/ShieldTrainer
echo "› rebuilding app with the model"
./Tools/build.sh "${1:-release}"
