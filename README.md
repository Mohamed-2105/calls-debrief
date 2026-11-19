# calls-debrief

Turns recordings of job interviews into a structured, coaching-oriented debrief in Notion.

Drop an audio file (or a transcript) into a Google Drive folder, run the pipeline, and get a Notion page with:

- **The role / the company**: everything the interviewer explained (tasks, team, tools, process, next steps), kept faithful to their words
- **Overall assessment** of the candidate's performance
- **To-do list**: follow-ups, topics to revise, documents to send
- **Strengths** and **areas for improvement**
- **Question-by-question breakdown**: the question as asked, what the recruiter was assessing, the candidate's answer (near-verbatim), and a neutral diagnosis

The analysis is written in French; questions, answers and the role description stay in their original language.

## How it works

```
01_A_Traiter/           1. Transcription        2. Analysis           3. Export           4. Archive
  .m4a .mp3 .wav   ──▶  mlx-whisper         ──▶  Gemini (structured ──▶ Notion page   ──▶  02_Archives/
  .txt .vtt .srt        + pyannote (local)        JSON output)          in a database
                        or read + clean text
                               │
                               └──▶ 03_Transcripts/ (transcript as sent to Gemini)
```

### Transcription and speaker detection

Audio files go through two local models. Each one runs in its own process, so its memory is fully released before the next one starts (both together don't fit on an 8 GB Mac):

1. **mlx-whisper** turns speech into text, cut into segments of a few seconds with start and end times. It doesn't know who is speaking.
2. **pyannote** (`speaker-diarization-community-1`) doesn't transcribe anything: it finds *who speaks when*, as speaker turns (`SPEAKER_00` from 12.3 s to 18.9 s, …). Its "exclusive" output is used, where only one person speaks at a time, so it lines up with Whisper's segments.

The two are then merged in `fusionner()` (`calls_debrief/etapes/transcription.py`):

- Each Whisper segment goes to the speaker whose turns overlap it the most.
- A segment that no turn overlaps at all is dropped. pyannote's turns double as voice activity detection (VAD): if it heard no voice there, the text is something Whisper made up over silence (typically the same phrase repeated at the start of a recording).
- Consecutive segments from the same speaker are joined into one line.

The result looks like this, and is what Gemini receives:

```
SPEAKER_01 : Yeah, of course. You already talked to Sarah, right?
SPEAKER_00 : Yeah, exactly.
SPEAKER_01 : So maybe we just dive in. […] what are you looking for?
SPEAKER_00 : Super clear. So I'm actually a student in a data science master's program, […]
```

pyannote doesn't know names, only that there are distinct voices. The prompt tells Gemini that these labels come from automatic detection and that it must work out from context which one is the candidate (`CANDIDATE_NAME`).

Diarization is optional: without `HF_TOKEN`, or if pyannote fails (model access, network, killed by macOS for lack of memory…), the pipeline falls back to Whisper's plain text and Gemini infers speakers from content alone. Whisper's segments are cached in `.etat/transcripts/` *before* pyannote runs, so the next run only retries diarization.

pyannote runs on the CPU by default, in small batches, which keeps its memory low. Set `DIARISATION_DEVICE=mps` to use the Apple GPU instead: faster, but it needs more memory.

```
calls-debrief/
├── pipeline_calls.py          # entry point
├── installer_app.py           # builds and installs the menu bar app
├── enregistrer.py             # records a video call from the terminal
├── outils/
│   ├── commun/Capture.swift   # capture engine: computer sound + microphone, via ScreenCaptureKit
│   ├── app/main.swift         # menu bar app: call detection, recording, automatic transcription
│   └── enregistreur/main.swift  # terminal recorder
└── calls_debrief/
    ├── config.py              # environment variables, folders, extensions, model names
    ├── schemas.py             # Pydantic schema of the debrief (Gemini's response schema)
    ├── etat.py                # local state in .etat/: transcript and segment cache, files already sent
    ├── enregistrement.py      # compiles the terminal recorder, mixes the two tracks into 01_A_Traiter
    ├── apres_enregistrement.py  # run by the app after a recording: mix, then transcribe
    ├── app.py                 # builds ~/Applications/Calls Debrief.app
    ├── etapes/                # pipeline steps
    │   ├── transcription.py   # mlx-whisper + pyannote and their merge; .vtt/.srt cleanup
    │   ├── analyse.py         # Gemini prompt and retry logic
    │   └── archivage.py       # move to 02_Archives, save transcripts to 03_Transcripts, without overwriting
    └── notion/                # Notion export
        ├── cible.py           # detects database vs page, maps the debrief onto existing columns
        ├── blocs.py           # page content (respects the 2000-character limit)
        └── export.py          # page creation, appending blocks beyond 100
```

### Reliability

- **One failing file doesn't stop the batch**: it stays in `01_A_Traiter` and is listed at the end.
- **Transcripts are cached** until the Notion page is created, so a Gemini or Notion failure never re-runs Whisper.
- **No duplicate pages**: if archiving fails after the page is created, the next run only archives.
- **No overwritten archives**: a timestamp is added if the file name already exists in `02_Archives`.

## Requirements

- macOS on **Apple Silicon** (mlx-whisper runs on the Apple GPU; text transcripts work anywhere)
- Python 3.13 (tested)
- A [Gemini API key](https://aistudio.google.com/apikey)
- A [Notion integration](https://www.notion.so/my-integrations) with access to the target database or page
- Google Drive for desktop (or any local folder; see `CALLS_FOLDER`)

ffmpeg is provided by `static-ffmpeg`, which downloads its binaries on first use. The Whisper model (`whisper-large-v3-turbo`, about 1.6 GB) is downloaded on the first transcription. The pyannote model is downloaded on first use too (requires `HF_TOKEN`).

## Setup

```bash
git clone <repo-url> calls-debrief
cd calls-debrief
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env   # then fill in your keys
```

### `.env`

| Variable | Required | Description |
|---|---|---|
| `NOTION_TOKEN` | yes | Notion integration secret |
| `GEMINI_API_KEY` | yes | Gemini API key |
| `NOTION_TARGET` | yes | ID **or link** of the Notion database or page that receives the debriefs |
| `CANDIDATE_NAME` | yes | First name of the person being interviewed. Used to tell them apart from the interviewer in the transcript, and in the debrief headings |
| `HF_TOKEN` | no | Hugging Face token for speaker diarization. Accept the terms of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) first. Without it, transcripts have no speaker labels |
| `DIARISATION_DEVICE` | no | `cpu` (default, uses less memory) or `mps` (Apple GPU, faster but uses more memory) for pyannote |
| `CALLS_FOLDER` | no | Working folder (default `~/assistant-calls`), e.g. `~/Documents/Calls Debrief`. After changing it, re-run `installer_app.py` so the app uses the new folder |

Share the target with your integration in Notion (`•••` → *Connections*), otherwise the API can't see it.

### Notion target: any database or page

The pipeline reads the target's structure on each run and adapts to it. Nothing needs to be renamed or created.

**A database** → each debrief becomes a row. The page content is always complete; the only thing that varies is which columns get filled:

| Column found in your database | Filled with |
|---|---|
| The title column, whatever its name | Interview title |
| `Espace` (select) | Gemini picks one of **your** existing options |
| `Catégorie` / `Category` (select) | `Interview` |
| `Date` / `Date de l'entretien` / `Interview date` (date) | Date mentioned in the interview, if any |
| `Interlocuteurs` / `Recruteurs` / `Interviewers` (multi-select or text) | Interviewer names and roles |

Names are compared ignoring case, accents and special spaces (`Catégorie`, `categorie` and `Relue ?` with a non-breaking space all match). Missing columns are skipped and listed at startup; other columns are left untouched.

**A plain page** → each debrief is created as a sub-page.

`.calls_database_id` (a file holding an ID) is still read as a fallback when `NOTION_TARGET` is not set.

### Folders

Set `CALLS_FOLDER` in `.env` to your own folder. The pipeline reads from `CALLS_FOLDER/01_A_Traiter` archives to `CALLS_FOLDER/02_Archives`, and writes each transcript as sent to Gemini (with speaker labels when diarization ran) to `CALLS_FOLDER/03_Transcripts/<file name>.txt`. All three are created if they don't exist.

## Usage

```bash
.venv/bin/python pipeline_calls.py
```

Every supported file in `01_A_Traiter` is processed. To skip a file, move it out of that folder.

A 30-minute recording takes about 16 minutes on an M1: about 8 for Whisper and 8 for pyannote, plus under a minute for Gemini and Notion. Without `HF_TOKEN`, about 8 minutes. These times were measured with pyannote on the GPU. On the CPU (now the default), pyannote may be slower; this hasn't been measured yet.

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

Renaming and deleting are disabled while a transcription runs.

### Phone calls

Record with Dictaphone (Voice Memos) or the iPhone's call recording, then get the file onto the Mac:
- **If Voice Memos syncs with iCloud**: drag the recording from the Mac's Voice Memos app onto the drop zone.
- **Otherwise**: AirDrop it to the Mac, then drag it from Downloads onto the drop zone.

**Always tell the other participants that you are recording.** In France, recording a private conversation without consent is an offence (article 226-1 of the Code pénal).

## Configuration

In `calls_debrief/config.py`:

- `MODELES_GEMINI`: Gemini models tried in order
- `MODELE_WHISPER`: Whisper model from Hugging Face
- `EXTENSIONS_AUDIO` / `EXTENSIONS_TEXTE`: accepted formats

The prompt (`PROMPT_DEBRIEF` in `calls_debrief/etapes/analyse.py`) and the field descriptions in `calls_debrief/schemas.py` drive what Gemini extracts; edit both to change the debrief.

## Limitations

- A Whisper segment where the speaker changes mid-sentence goes entirely to one speaker, and when both people talk at once their words can end up in the same line.
- Short interjections ("yeah", "ok") said while the other person is talking are absorbed into that person's line.
- Overlapping speech, background noise or a third voice can make pyannote detect an extra speaker.
- In `.vtt`/`.srt` files, a line containing only digits is treated as a cue number and removed.
