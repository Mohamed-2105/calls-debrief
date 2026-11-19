"""Avancement de la transcription en cours, lu par l'app de la barre des menus (.etat/progression.json).

Écrit par le processus principal (fichier, étape) et par les processus enfants Whisper/pyannote (pourcentage)."""
import json
import os
import time

from calls_debrief.etat import DOSSIER_ETAT

FICHIER = os.path.join(DOSSIER_ETAT, "progression.json")
_INTERVALLE = 1.0  # secondes minimum entre deux écritures du pourcentage
_derniere_ecriture = 0.0

def _lire() -> dict:
    try:
        with open(FICHIER, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def _ecrire(donnees: dict):
    os.makedirs(DOSSIER_ETAT, exist_ok=True)
    temporaire = FICHIER + ".tmp"
    with open(temporaire, "w", encoding="utf-8") as f:
        json.dump(donnees, f, ensure_ascii=False)
    os.replace(temporaire, FICHIER)  # l'app ne lit jamais un fichier à moitié écrit

def etape(texte: str, fichier: str | None = None):
    """Nouvelle étape (pourcentage remis à zéro). fichier : nom du fichier traité, gardé si absent."""
    donnees = _lire()
    if fichier is not None:
        donnees["fichier"] = fichier
    donnees.update(etape=texte, fraction=None, debut=time.time())
    _ecrire(donnees)

def avancement(fait: float, total: float):
    """Pourcentage de l'étape en cours (écritures espacées d'au moins une seconde)."""
    global _derniere_ecriture
    maintenant = time.time()
    if not total or (maintenant - _derniere_ecriture < _INTERVALLE and fait < total):
        return
    _derniere_ecriture = maintenant
    donnees = _lire()
    donnees["fraction"] = max(0.0, min(1.0, fait / total))
    _ecrire(donnees)

def effacer():
    try:
        os.remove(FICHIER)
    except FileNotFoundError:
        pass
