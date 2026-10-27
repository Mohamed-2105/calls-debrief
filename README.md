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

Audio files go through two local models, both on the Apple GPU:

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

Diarization is optional: without `HF_TOKEN`, or if pyannote fails (model access, network…), the pipeline falls back to Whisper's plain text and Gemini infers speakers from content alone.

```
calls-debrief/
├── pipeline_calls.py          # entry point
└── calls_debrief/
    ├── config.py              # environment variables, folders, extensions, model names
    ├── schemas.py             # Pydantic schema of the debrief (Gemini's response schema)
    ├── etat.py                # local state in .etat/: transcript cache, files already sent
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
| `CALLS_FOLDER` | no | Working folder (default `~/assistant-calls`), e.g. a synced Google Drive folder |

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

A 30-minute recording takes about 16 minutes on an M1: about 8 for Whisper and 8 for pyannote, plus under a minute for Gemini and Notion. Without `HF_TOKEN`, about 8 minutes.

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
