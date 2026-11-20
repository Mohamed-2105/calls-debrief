# calls-debrief

Records and transcribes calls (job interviews, work and personal calls) locally on a Mac, then writes AI summaries tailored to each kind of call.

A menu bar app records the call (computer sound + microphone), or you drop an audio file or a transcript into it. You get:

- **A transcript with speakers**: mlx-whisper + pyannote, run locally
- **Names pre-filled** for each speaker and for the call, which you validate in the app
- **A light cleanup** of recognition errors (Claude Haiku)
- **An AI summary** per call, with an editable prompt per category (*Entretien*, *Call pro*, *Call perso*, *Neutre*)

## How it works

```
01_A_Traiter/           1. Transcription         2. Names              3. In the app
  .m4a .mp3 .wav   ──▶  mlx-whisper         ──▶  Claude Haiku /   ──▶  validate names, cleanup,
  .txt .vtt .srt        + pyannote (local)        Gemini propose       AI summary → 04_Resumes/
                        or read + clean text
                               │
                               └──▶ 03_Transcripts/
```

### Transcription and speaker detection

Audio files go through two local models. Each one runs in its own process, so its memory is fully released before the next one starts (both together don't fit on an 8 GB Mac):

1. **mlx-whisper** turns speech into text, cut into segments of a few seconds with start and end times. It doesn't know who is speaking.
2. **pyannote** (`speaker-diarization-community-1`) doesn't transcribe anything: it finds *who speaks when*, as speaker turns (`SPEAKER_00` from 12.3 s to 18.9 s, …). Its "exclusive" output is used, where only one person speaks at a time, so it lines up with Whisper's segments.

The two are then merged in `fusionner()` (`calls_debrief/etapes/transcription.py`):

- Each Whisper segment goes to the speaker whose turns overlap it the most.
- A speaker with less than `DUREE_MIN_LOCUTEUR` seconds (20 s) of speech over the whole call is treated as a false detection (one voice split in two, background noise): their segments go to the next most present speaker.
- A segment that no turn overlaps at all is dropped. pyannote's turns double as voice activity detection (VAD): if it heard no voice there, the text is something Whisper made up over silence (typically the same phrase repeated at the start of a recording).
- Consecutive segments from the same speaker are joined into one line.

The result looks like this:

```
SPEAKER_01 : Yeah, of course. You already talked to Sarah, right?
SPEAKER_00 : Yeah, exactly.
SPEAKER_01 : So maybe we just dive in. […] what are you looking for?
SPEAKER_00 : Super clear. So I'm actually a student in a data science master's program, […]
```

Before the merge, Whisper's hallucinations are removed locally (`nettoyer_texte()`): a sentence repeated several times in a row is kept once, a segment that is only the same sentence repeated 3+ times is dropped ("Thank you. Thank you. Thank you…"), and known subtitle artefacts ("Sous-titres réalisés par…") are removed. Whisper also runs with `condition_on_previous_text=False`, which stops most of these loops at the source.

### Naming speakers and the call (you validate)

pyannote doesn't know names, only that there are distinct voices. After each transcription, `etapes/identification.py` asks Gemini to pre-fill who is behind each `SPEAKER_XX` and a name for the call, in the format `Company - First Last (Role)` (e.g. `Acme - Julie Martin (Head of GTM Eng.)`). Gemini only returns these names, it never rewrites the transcript.

Nothing is applied automatically. The proposal is stored in `.etat/propositions.json`, and the app shows it above the transcript (✨ in the list): each label with a typical line to recognise the voice, an editable name with suggestions, and the call name. **Valider** renames the call (audio, transcript and cache together) and replaces the labels in the transcript; giving two labels the same name merges their lines. **Ignorer** keeps `SPEAKER_XX`. Without `GEMINI_API_KEY`, or if Gemini fails, the panel still appears with empty fields.

Files that already have a transcript in `03_Transcripts` are no longer reprocessed.

Diarization is optional: without `HF_TOKEN`, or if pyannote fails (model access, network, killed by macOS for lack of memory…), the pipeline falls back to Whisper's plain text, without speaker labels. Whisper's segments are cached in `.etat/transcripts/` *before* pyannote runs, so the next run only retries diarization.

pyannote runs on the CPU by default, in small batches, which keeps its memory low. Set `DIARISATION_DEVICE=mps` to use the Apple GPU instead: faster, but it needs more memory.

```
calls-debrief/
├── pipeline_calls.py          # entry point
├── tests/                     # pytest tests (no models, no network)
├── installer_app.py           # builds and installs the menu bar app
├── enregistrer.py             # records a video call from the terminal
├── outils/
│   ├── commun/Capture.swift   # capture engine: computer sound + microphone, via ScreenCaptureKit
│   ├── app/main.swift         # menu bar app: call detection, recording, automatic transcription
│   ├── app/Fenetre.swift      # main window: history, validation panel, categories, summaries
│   ├── app/Prompts.swift      # categories, summary formats, base prompts window
│   └── enregistreur/main.swift  # terminal recorder
└── calls_debrief/
    ├── config.py              # environment variables, folders, extensions, model names
    ├── etat.py                # local state in .etat/: transcript and segment cache, name proposals, prompts and profile paths
    ├── gemini.py              # Gemini calls (JSON or plain text), retries and model fallback
    ├── resume.py              # AI summary of a call, run from the app (formats and default prompts)
    ├── secours.py             # summary fallback on OVHcloud AI Endpoints when Gemini fails
    ├── claude.py              # Claude API calls (Sonnet / Haiku), cost logging
    ├── nettoyage.py           # light transcript cleanup by Claude Haiku (raw kept in 03_Transcripts/.bruts)
    ├── enregistrement.py      # compiles the terminal recorder, mixes the two tracks into 01_A_Traiter
    ├── apres_enregistrement.py  # run by the app after a recording: mix, then transcribe
    ├── app.py                 # builds ~/Applications/Calls Debrief.app
    ├── etapes/                # pipeline steps
    │   ├── transcription.py   # mlx-whisper + pyannote and their merge, hallucination filters; .vtt/.srt cleanup
    │   ├── identification.py  # speaker names, call name and category pre-filled by Gemini, validated in the app
    │   └── archivage.py       # saves transcripts to 03_Transcripts without overwriting
```

### Reliability

- **One failing file doesn't stop the batch**: it stays in `01_A_Traiter` and is listed at the end.
- **Whisper's output is cached** in `.etat/transcripts/`, so a later failure (pyannote, name proposal) never re-runs Whisper.
- **No overwritten transcripts**: a timestamp is added if a different transcript with the same name already exists in `03_Transcripts`.

## Requirements

- macOS on **Apple Silicon** (mlx-whisper runs on the Apple GPU; text transcripts work anywhere)
- Python 3.13 (tested)
- Optional: a [Claude API key](https://console.anthropic.com/) and/or a [Gemini API key](https://aistudio.google.com/apikey) for names, cleanup and summaries

ffmpeg is provided by `static-ffmpeg`, which downloads its binaries on first use. The Whisper model (`whisper-large-v3-turbo`, about 1.6 GB) is downloaded on the first transcription. The pyannote model is downloaded on first use too (requires `HF_TOKEN`).

## Setup

```bash
git clone <repo-url> calls-debrief
cd calls-debrief
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt   # requirements.txt + pytest
cp .env.example .env   # then fill in your keys
```

### `.env`

| Variable | Required | Description |
|---|---|---|
| `CANDIDATE_NAME` | yes | Your first name. Used to tell you apart from the other people in the transcript and in the summaries |
| `ANTHROPIC_API_KEY` | no | Claude API key: speaker names, transcript cleanup and summaries (see *Models* below) |
| `GEMINI_API_KEY` | no | Gemini API key: fallback when Claude fails or has no key |
| `OVH_AI_ENDPOINTS_ACCESS_TOKEN` | no | Raises the rate limit of the OVHcloud summary fallback |
| `HF_TOKEN` | no | Hugging Face token for speaker diarization. Accept the terms of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) first. Without it, transcripts have no speaker labels |
| `DIARISATION_DEVICE` | no | `cpu` (default, uses less memory) or `mps` (Apple GPU, faster but uses more memory) for pyannote |
| `CALLS_FOLDER` | no | Working folder (default `~/assistant-calls`), e.g. `~/Documents/Calls Debrief`. After changing it, re-run `installer_app.py` so the app uses the new folder |

### Folders

Set `CALLS_FOLDER` in `.env` to your own folder. The pipeline reads from `CALLS_FOLDER/01_A_Traiter` (audio stays there after transcription) and writes each transcript (with speaker labels when diarization ran) to `CALLS_FOLDER/03_Transcripts/<file name>.txt`. Summaries go to `CALLS_FOLDER/04_Resumes`. `02_Archives` only holds audio from older versions; the app still lists it.

## Usage

```bash
.venv/bin/python pipeline_calls.py
```

Every supported file in `01_A_Traiter` that has no transcript yet in `03_Transcripts` is processed. To skip a file, move it out of that folder.

A 30-minute recording takes about 16 minutes on an M1: about 8 for Whisper and 8 for pyannote, plus a few seconds for the name proposal. Without `HF_TOKEN`, about 8 minutes. These times were measured with pyannote on the GPU. On the CPU (now the default), pyannote may be slower; this hasn't been measured yet.

## Recording an interview

### Video calls (Zoom, Meet, Teams…): the menu bar app

Install it once:

```bash
.venv/bin/python installer_app.py
```

This builds `~/Applications/Calls Debrief.app` and launches it. A microphone icon appears in the menu bar. Then:

1. **When a call starts**, a notification appears: *"Appel détecté (zoom.us) — Enregistrer ?"*. Click **Enregistrer**. You can also start from the menu (*Enregistrer*) at any time.
2. **During the call**, the icon turns red and shows the elapsed time. The app records **the computer's sound** (the other participants) and **your microphone**.
3. **When the call ends**, recording stops by itself one minute after the call app releases the microphone. You can also stop it from the menu (*Arrêter et transcrire*).
4. **Transcription starts automatically.** The two tracks are mixed into `01_A_Traiter/appel_YYYY-MM-DD_HHhMM.m4a`, then `pipeline_calls.py` runs in the background. A notification tells you when the transcript is in `03_Transcripts`. Click it to open the folder.

How call detection works: every 2 seconds the app checks which apps are using the microphone, ignoring macOS's own services (Siri, dictation…) except FaceTime and Safari. It only *offers* to record, so you never record a call by accident and you're reminded to tell the other person.

Menu options:
- *Proposer d'enregistrer les appels*: turn detection on or off.
- *Lancer au démarrage du Mac*: start the app at login.
- *Ouvrir la corbeille*: open the folder of deleted calls (see below).
- *Voir le dernier journal*: open the last transcription log, kept in `.etat/journaux/`.

Requirements and permissions:
- **macOS 15+**, with the developer tools (`xcode-select --install`) to compile the app.
- On first use, allow **Calls Debrief** in *System Settings → Privacy & Security*, under **Screen & System Audio Recording** and under **Microphone**, and allow its notifications.
- **Re-running `installer_app.py` (after a code change) may ask for these permissions again**: the app is signed locally, so macOS treats each build as a new app.
- Headphones are recommended but not required. Without them, the other participants' voices also reach your microphone, which adds a slight echo.
- Raw tracks are kept in `.etat/enregistrements/` until they are mixed. If the app quits mid-call or mixing fails, nothing is lost: pending recordings are picked up the next time a transcription runs.

From the terminal instead: `.venv/bin/python enregistrer.py`, then `Ctrl+C` to stop. Closing the window also saves the recording. Transcription is not started automatically in this mode.

### The app window: drop a recording, read transcripts

Open **Calls Debrief** from the Finder (*Applications* in your home folder, i.e. `~/Applications`), Spotlight, or the Dock if you drag it there — or menu → *Ouvrir Calls Debrief*, or click the "Transcription terminée" notification. When the app starts at login, it stays in the menu bar without opening the window. The window shows:

- **a drop zone**: drop an audio file (m4a, mp3, wav) or a transcript (txt, vtt, srt), or click it to pick a file. The file is copied into `01_A_Traiter` and transcription starts right away;
- **a progress banner** while a transcription runs: file, current step (preparing the recording, transcription, speaker identification), percentage, elapsed time, and *Voir le journal*. The menu bar menu shows the same step;
- **the call history**, including calls waiting for or undergoing transcription, sorted by call date (newest or oldest first) or by name (A→Z, Z→A). The call date comes from the `appel_…` file name, otherwise from the date stored in the audio by Voice Memos, otherwise from the oldest file. It is saved in `03_Transcripts/.calls-debrief.json`, so copying or renaming files does not change it;
- **the transcript** of the selected call, with *Copier*, *Afficher dans le Finder* and a trash button.

**Renaming**: double-click a call's name (in the list or above the transcript), or hover it and click the pencil. Type, then Enter (or click elsewhere) to confirm, Escape to cancel. Renaming changes the transcript, the audio (in `01_A_Traiter` and `02_Archives`) and the transcription cache together, so the call is not transcribed again.

**Deleting**: the trash button, right-click → *Mettre à la corbeille*, or the Delete key. All the call's files (transcript, audio, cache) move to `Corbeille/<name> — supprimé le <date>/` in the project folder, sorted by origin folder: to restore a call, move them back. Menu → *Ouvrir la corbeille* opens it. Items older than 30 days are deleted for good (checked at launch and every hour); change `DUREE_CORBEILLE_JOURS` (or `DOSSIER_CORBEILLE`) in `calls_debrief/config.py`, then re-run `installer_app.py`.

Renaming and deleting are disabled while a transcription runs (and, for one call, while its AI summary is being generated).

### Transcript cleanup (Claude Haiku)

With `ANTHROPIC_API_KEY` set, validating (or ignoring) the names in the app starts a light cleanup of the transcript by Claude Haiku (`calls_debrief/nettoyage.py`, about 1 cent and 30 seconds per call): it fixes misrecognised words (proper nouns, tools, jargon: "Cloud Code" → "Claude Code", "outband" → "outbound"), punctuation and leftover hesitations, and keeps everything else as said (verbal tics, swearing, unfinished sentences), so interview feedback can still judge how you speak. Whisper already drops most "euh". The raw transcript is kept in `03_Transcripts/.bruts/` (renamed and trashed with the call); a new cleanup always starts from it. The transcript is cut into chunks; a chunk whose cleaned version is much shorter or longer than the original, or shows a speaker that wasn't there, keeps its raw text. Use the *Nettoyer* button (or right-click) for older transcripts.

### Categories and AI summaries

**Categories**: each call is *Entretien*, *Call pro* or *Call perso*. Gemini proposes one at the end of the transcription, in the validation panel next to the call name; change it anytime from the menu under the call's date or with right-click → *Catégorie*. The menu at the top of the list filters calls by category (or shows *Non classés*). Categories are stored in `03_Transcripts/.calls-debrief.json`, next to the dates.

**AI summary**: the *Résumé IA* button above a transcript opens a sheet with:
- the **format**: *Entretien*, *Call pro*, *Call perso* or *Neutre* ("Résume ce call."). It defaults to the call's category (Neutre if it has none);
- the format's **prompt**, pre-filled and editable: your changes apply to this summary only (*Revenir au prompt de base* undoes them).

Gemini runs in the background (`python -m calls_debrief.resume`, log in `.etat/journaux/…-resume.log`), even while another call is being transcribed, and a notification tells you when it's done. The tab shows the current step.

**Models**: with `ANTHROPIC_API_KEY` in `.env`, *Entretien* summaries use **Claude Sonnet 5.5** (medium reasoning effort, about 5–8 cents each) and the other formats **Claude Haiku 5.5** (about 0.3 cent); each summary's first line shows the model and its real cost, and every Claude call is logged to `.etat/couts_claude.jsonl`. Speaker names, call name and category also go to Haiku first, then Gemini. If Claude fails or has no key, summaries go to Gemini (one try per model), then to **OVHcloud AI Endpoints** (`calls_debrief/secours.py`, model `MODELE_SECOURS` in `config.py`, EU-hosted, about 1 minute). It works without an account (anonymous access, 2 requests/min per model); an `OVH_AI_ENDPOINTS_ACCESS_TOKEN` in `.env` (from a paid Public Cloud project) raises the limit. The summary's first line says which model wrote it. Formatting rules (Markdown, French, nothing invented) and the transcript are always appended to the prompt. The summary is saved as `CALLS_FOLDER/04_Resumes/<call name>.md` and shown in the *Résumé* tab; each call has one summary, and generating again replaces it. Renaming or deleting a call carries its summary along.

**Your profile**: the same window has a *Mon profil* tab: a few lines about you (background, what you're looking for, projects to highlight, known weak spots in interviews), saved to `.etat/profil.md` and added to every summary's context.

**Base prompts**: menu bar → *Prompts et profil des résumés…* (or the link in the sheet) to edit each format's default prompt. Changes are saved to `.etat/prompts.json`; *Rétablir le prompt par défaut* goes back to the default prompt. Defaults come from `prompts.json` at the project root (your own, git-ignored), or from `prompts.example.json` if it does not exist: copy it to start (`cp prompts.example.json prompts.json`), then rerun the app installer so *Rétablir* uses the new defaults.

### Phone calls

Record with Dictaphone (Voice Memos) or the iPhone's call recording, then get the file onto the Mac:
- **If Voice Memos syncs with iCloud**: drag the recording from the Mac's Voice Memos app onto the drop zone.
- **Otherwise**: AirDrop it to the Mac, then drag it from Downloads onto the drop zone.

**Always tell the other participants that you are recording.** In France, recording a private conversation without consent is an offence (article 226-1 of the Code pénal).

## Checks

```bash
./verifier.sh
```

Runs `ruff check --fix`, then `ruff check` (rules in `pyproject.toml`), imports every Python module, runs the tests in `tests/` (pytest), and type-checks the Swift app. Needs `ruff` (`brew install ruff`) and the dev dependencies (`.venv/bin/pip install -r requirements-dev.txt`).

The tests cover the logic that runs without models or network: Whisper hallucination filters, merging Whisper segments with pyannote turns, `.vtt`/`.srt` cleanup, transcript saving and cache, the name proposal, transcript cleanup safeguards, and the summary model fallback (Claude → Gemini → OVHcloud). API calls are replaced by fakes, and `tests/conftest.py` makes any real call fail the test. Run them alone with `.venv/bin/python -m pytest`.

## Configuration

In `calls_debrief/config.py`:

- `MODELES_GEMINI`: Gemini models tried in order
- `MODELE_WHISPER`: Whisper model from Hugging Face
- `EXTENSIONS_AUDIO` / `EXTENSIONS_TEXTE`: accepted formats
- `MODELE_ENTRETIEN` / `MODELE_LEGER`: Claude models for interview summaries / everything else

Summary prompts are edited in the app (see *Base prompts*); their defaults come from `prompts.json` (or `prompts.example.json`).

## Limitations

- A Whisper segment where the speaker changes mid-sentence goes entirely to one speaker, and when both people talk at once their words can end up in the same line.
- Short interjections ("yeah", "ok") said while the other person is talking are absorbed into that person's line.
- Overlapping speech, background noise or a third voice can make pyannote detect an extra speaker.
- In `.vtt`/`.srt` files, a line containing only digits is treated as a cue number and removed.
