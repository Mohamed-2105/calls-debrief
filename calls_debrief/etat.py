"""État local du pipeline : transcriptions en cache et fichiers déjà envoyés vers Notion."""
import json
import os

from calls_debrief.config import DOSSIER_PROJET

DOSSIER_ETAT = os.path.join(DOSSIER_PROJET, ".etat")
DOSSIER_CACHE_TRANSCRIPTS = os.path.join(DOSSIER_ETAT, "transcripts")
FICHIER_ENVOYES = os.path.join(DOSSIER_ETAT, "envoyes.json")

def cle_fichier(chemin: str) -> str:
    """Identifie un fichier par son nom et sa taille (stable malgré la synchro Google Drive)."""
    return f"{os.path.basename(chemin)}|{os.path.getsize(chemin)}"

# --- Cache des transcriptions (évite de relancer Whisper après un échec Gemini/Notion) ---
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

def supprimer_transcript_cache(cle: str):
    for extension in (".txt", ".segments.json"):
        try:
            os.remove(_chemin_cache(cle, extension))
        except FileNotFoundError:
            pass

# --- Registre des envois Notion (évite un doublon si l'archivage échoue) ---
def _lire_envoyes() -> dict:
    try:
        with open(FICHIER_ENVOYES, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def _ecrire_envoyes(envoyes: dict):
    os.makedirs(DOSSIER_ETAT, exist_ok=True)
    with open(FICHIER_ENVOYES, "w", encoding="utf-8") as f:
        json.dump(envoyes, f, ensure_ascii=False, indent=2)

def url_deja_envoye(cle: str) -> str | None:
    return _lire_envoyes().get(cle)

def marquer_envoye(cle: str, url: str | None):
    envoyes = _lire_envoyes()
    envoyes[cle] = url or ""
    _ecrire_envoyes(envoyes)

def oublier_envoi(cle: str):
    envoyes = _lire_envoyes()
    if envoyes.pop(cle, None) is not None:
        _ecrire_envoyes(envoyes)

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
