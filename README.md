# calls-debrief

Records and transcribes calls (job interviews, work and personal calls) locally on a Mac, then writes AI summaries tailored to each kind of call.

A menu bar app records the call (computer sound + microphone), or you drop an audio file or a transcript into its window. You get:

- **a transcript with speakers**: mlx-whisper + pyannote, run locally;
- **names pre-filled** for each speaker and for the call, which you validate in the app;
- **a light cleanup** of recognition errors (Claude Haiku);
- **an AI summary** per call, with an editable prompt per category (*Entretien*, *Call pro*, *Call perso*, *Neutre*).

## Requirements

- macOS 15+ on Apple Silicon, with the developer tools (`xcode-select --install`)
- Python 3.13
- Optional API keys: Claude and/or Gemini (names, cleanup, summaries), Hugging Face (speaker detection)

## Setup

```bash
git clone <repo-url> calls-debrief
cd calls-debrief
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
cp .env.example .env              # then fill in your keys
.venv/bin/python installer_app.py # builds and launches ~/Applications/Calls Debrief.app
```

On first use, allow **Calls Debrief** in *System Settings → Privacy & Security* under **Screen & System Audio Recording** and **Microphone**. Rebuilding the app may ask for these permissions again.

### `.env`

| Variable | Description |
|---|---|
| `CANDIDATE_NAME` | **Required.** Your first name, to tell you apart in transcripts and summaries |
| `ANTHROPIC_API_KEY` | Claude: speaker names, cleanup, summaries |
| `GEMINI_API_KEY` | Gemini: fallback when Claude fails or has no key |
| `HF_TOKEN` | Hugging Face token for speaker detection (accept the terms of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) first) |
| `CALLS_FOLDER` | Working folder (default `~/assistant-calls`); re-run `installer_app.py` after changing it |
| `DIARISATION_DEVICE` | `cpu` (default) or `mps` (faster, more memory) |
| `OVH_AI_ENDPOINTS_ACCESS_TOKEN` | Raises the rate limit of the OVHcloud summary fallback |

## Usage

- **Video calls**: when an app starts using the microphone, a notification offers to record. Recording stops on its own after the call, then transcription starts automatically.
- **Phone calls or other files**: drop an audio file (m4a, mp3, wav) or a transcript (txt, vtt, srt) onto the app window.
- **In the window**: validate the proposed names, then read, rename, categorise or delete calls and generate their summary (*Résumé IA*). Base prompts and your profile are edited from the menu bar (*Prompts et profil des résumés…*).

Files go through `CALLS_FOLDER`: `01_A_Traiter` (audio), `03_Transcripts`, `04_Resumes`. To process the folder from the terminal: `.venv/bin/python pipeline_calls.py`.

A 30-minute call takes about 15 minutes to transcribe on an M1.

**Always tell the other participants that you are recording.** In France, recording a private conversation without consent is an offence (article 226-1 of the Code pénal).

## How it works

1. **Transcription**: mlx-whisper turns speech into text, pyannote finds who speaks when, and the two are merged (`calls_debrief/etapes/transcription.py`). Each model runs in its own process to fit in 8 GB of RAM. Without `HF_TOKEN`, the transcript has no speaker labels.
2. **Names**: Claude Haiku (or Gemini) proposes a name for each speaker and for the call; nothing is applied until you validate it in the app.
3. **Cleanup**: Claude Haiku fixes misrecognised words and punctuation; the raw transcript is kept in `03_Transcripts/.bruts/`.
4. **Summary**: Claude Sonnet for interviews, Claude Haiku for other calls, with Gemini then OVHcloud as fallbacks. Default prompts come from `prompts.json` (copy `prompts.example.json` to start).

## Project structure

```
calls-debrief/
├── pipeline_calls.py            # entry point: transcribes everything in 01_A_Traiter
├── installer_app.py             # builds and installs the menu bar app
├── enregistrer.py               # records a call from the terminal
├── prompts.example.json         # default summary prompts (copy to prompts.json)
├── verifier.sh                  # ruff, imports, pytest, Swift type-check
├── tests/                       # pytest tests (no models, no network)
├── outils/
│   ├── app/                     # menu bar app and main window (Swift)
│   ├── commun/Capture.swift     # records computer sound + microphone
│   ├── enregistreur/main.swift  # terminal recorder
│   └── icone/main.swift         # draws the app icon
└── calls_debrief/
    ├── config.py                # environment variables, folders, models
    ├── etat.py                  # local state in .etat/ (cache, proposals, prompts, profile)
    ├── progression.py           # transcription progress shown by the app
    ├── etapes/
    │   ├── transcription.py     # mlx-whisper + pyannote and their merge
    │   ├── identification.py    # proposed speaker names, call name and category
    │   └── archivage.py         # saves transcripts to 03_Transcripts
    ├── nettoyage.py             # transcript cleanup (Claude Haiku)
    ├── resume.py                # AI summaries
    ├── claude.py / gemini.py / secours.py  # Claude, Gemini and OVHcloud clients
    ├── enregistrement.py        # mixes recorded tracks into 01_A_Traiter
    ├── apres_enregistrement.py  # run after a recording: mix, then transcribe
    └── app.py                   # builds ~/Applications/Calls Debrief.app
```

## Checks

```bash
./verifier.sh   # ruff, imports, pytest, Swift type-check
```
