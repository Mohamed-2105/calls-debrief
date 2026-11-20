"""État local du pipeline : transcriptions en cache, propositions de noms, prompts et profil de l'app."""
import json
import os

from calls_debrief.config import DOSSIER_PROJET

DOSSIER_ETAT = os.path.join(DOSSIER_PROJET, ".etat")
DOSSIER_CACHE_TRANSCRIPTS = os.path.join(DOSSIER_ETAT, "transcripts")

def cle_fichier(chemin: str) -> str:
    """Identifie un fichier par son nom et sa taille (stable même si le dossier est copié ou synchronisé)."""
    return f"{os.path.basename(chemin)}|{os.path.getsize(chemin)}"

# --- Cache des transcriptions (évite de relancer Whisper après un échec) ---
def _chemin_cache(cle: str, extension: str = ".txt") -> str:
    return os.path.join(DOSSIER_CACHE_TRANSCRIPTS, cle.replace("|", "_").replace(os.sep, "_") + extension)

def lire_transcript_cache(cle: str) -> str | None:
    try:
        with open(_chemin_cache(cle), encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None

def ecrire_transcript_cache(cle: str, texte: str):
    os.makedirs(DOSSIER_CACHE_TRANSCRIPTS, exist_ok=True)
    with open(_chemin_cache(cle), "w", encoding="utf-8") as f:
        f.write(texte)

# Segments Whisper bruts : écrits avant pyannote, pour ne jamais refaire Whisper si la diarisation plante
def lire_segments_cache(cle: str) -> list | None:
    try:
        with open(_chemin_cache(cle, ".segments.json"), encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def ecrire_segments_cache(cle: str, segments: list):
    os.makedirs(DOSSIER_CACHE_TRANSCRIPTS, exist_ok=True)
    with open(_chemin_cache(cle, ".segments.json"), "w", encoding="utf-8") as f:
        json.dump(segments, f, ensure_ascii=False)

# --- Propositions à valider dans l'app (noms des locuteurs, nom de l'appel) : {nom du transcript: proposition} ---
FICHIER_PROPOSITIONS = os.path.join(DOSSIER_ETAT, "propositions.json")

def enregistrer_proposition(fichier: str, proposition: dict):
    try:
        with open(FICHIER_PROPOSITIONS, encoding="utf-8") as f:
            propositions = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        propositions = {}
    propositions[fichier] = proposition
    os.makedirs(DOSSIER_ETAT, exist_ok=True)
    temporaire = FICHIER_PROPOSITIONS + ".tmp"
    with open(temporaire, "w", encoding="utf-8") as f:
        json.dump(propositions, f, ensure_ascii=False, indent=2)
    os.replace(temporaire, FICHIER_PROPOSITIONS)  # l'app ne lit jamais un fichier à moitié écrit

# --- Prompts des résumés modifiés dans l'app : {format: texte} (les autres gardent le prompt par défaut) ---
FICHIER_PROMPTS = os.path.join(DOSSIER_ETAT, "prompts.json")
# Profil de l'utilisateur (parcours, objectifs…), écrit dans l'app et ajouté au contexte de chaque résumé
FICHIER_PROFIL = os.path.join(DOSSIER_ETAT, "profil.md")
