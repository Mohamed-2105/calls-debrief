"""Garde-fous communs : aucun test n'appelle une API (Claude, Gemini, OVHcloud) ni n'écrit dans le vrai .etat/."""
import pytest

from calls_debrief import claude, config, etat, resume
from calls_debrief.etapes import identification


@pytest.fixture(autouse=True)
def sans_reseau_ni_etat(monkeypatch, tmp_path):
    def interdit(*args, **kwargs):
        raise AssertionError("Un test a tenté d'appeler une API : remplace la fonction par un faux avec monkeypatch.")

    monkeypatch.setattr(claude, "generer_texte", interdit)
    monkeypatch.setattr(claude, "generer_json", interdit)
    monkeypatch.setattr(claude, "disponible", lambda: False)
    # Chaque module garde sa propre copie de la clé (from config import GEMINI_API_KEY)
    for module in (config, identification, resume):
        monkeypatch.setattr(module, "GEMINI_API_KEY", None)

    dossier_etat = tmp_path / "etat"
    monkeypatch.setattr(etat, "DOSSIER_ETAT", str(dossier_etat))
    monkeypatch.setattr(etat, "DOSSIER_CACHE_TRANSCRIPTS", str(dossier_etat / "transcripts"))
    monkeypatch.setattr(etat, "FICHIER_PROPOSITIONS", str(dossier_etat / "propositions.json"))
