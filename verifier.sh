#!/bin/sh
# Vérifications à lancer après chaque modification : ruff (corrige ce qui peut l'être, puis vérifie),
# imports des modules Python, tests (pytest), compilation de l'app Swift.
set -e
cd "$(dirname "$0")"

if ! command -v ruff >/dev/null 2>&1; then
    echo "ruff introuvable : brew install ruff (ou pip install ruff)"; exit 1
fi
echo "== ruff check --fix"
ruff check --fix .
echo "== ruff check"
ruff check .

echo "== imports Python"
.venv/bin/python -c "
import pipeline_calls, calls_debrief.app, calls_debrief.resume, calls_debrief.nettoyage, calls_debrief.claude
import calls_debrief.secours, calls_debrief.gemini, calls_debrief.etapes.identification"

echo "== tests"
if ! .venv/bin/python -c "import pytest" 2>/dev/null; then
    echo "pytest introuvable : .venv/bin/pip install -r requirements-dev.txt"; exit 1
fi
.venv/bin/python -m pytest -q

echo "== compilation Swift (app)"
swiftc -typecheck outils/commun/Capture.swift outils/app/*.swift 2>&1 | grep -E "error" && exit 1

echo "OK"
