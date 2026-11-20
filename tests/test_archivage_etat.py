import json
import os

import pytest

from calls_debrief import etat
from calls_debrief.etapes import archivage


@pytest.fixture
def transcripts(monkeypatch, tmp_path):
    dossier = tmp_path / "03_Transcripts"
    dossier.mkdir()
    monkeypatch.setattr(archivage, "DOSSIER_TRANSCRIPTS", str(dossier))
    return dossier


def test_sauvegarder_transcript_ecrit_un_txt_du_meme_nom(transcripts):
    destination = archivage.sauvegarder_transcript("/ailleurs/appel_2026.m4a", "SPEAKER_00 : Bonjour.")
    assert destination == str(transcripts / "appel_2026.txt")
    assert (transcripts / "appel_2026.txt").read_text(encoding="utf-8") == "SPEAKER_00 : Bonjour."


def test_meme_transcription_ne_cree_pas_de_doublon(transcripts):
    premier = archivage.sauvegarder_transcript("appel.m4a", "texte")
    second = archivage.sauvegarder_transcript("appel.m4a", "texte")
    assert premier == second
    assert os.listdir(transcripts) == ["appel.txt"]


def test_transcription_differente_n_ecrase_pas(transcripts):
    archivage.sauvegarder_transcript("appel.m4a", "premier appel")
    destination = archivage.sauvegarder_transcript("appel.wav", "second appel")
    assert destination != str(transcripts / "appel.txt")
    assert os.path.basename(destination).startswith("appel_")
    assert (transcripts / "appel.txt").read_text(encoding="utf-8") == "premier appel"
    assert open(destination, encoding="utf-8").read() == "second appel"


def test_cle_fichier_nom_et_taille(tmp_path):
    fichier = tmp_path / "appel.m4a"
    fichier.write_bytes(b"12345")
    assert etat.cle_fichier(str(fichier)) == "appel.m4a|5"


def test_cache_transcript_et_segments():
    cle = "appel.m4a|5"
    assert etat.lire_transcript_cache(cle) is None
    assert etat.lire_segments_cache(cle) is None
    etat.ecrire_transcript_cache(cle, "texte")
    etat.ecrire_segments_cache(cle, [{"start": 0, "end": 1, "text": "Bonjour"}])
    assert etat.lire_transcript_cache(cle) == "texte"
    assert etat.lire_segments_cache(cle) == [{"start": 0, "end": 1, "text": "Bonjour"}]


def test_enregistrer_proposition_ajoute_sans_effacer_les_autres():
    etat.enregistrer_proposition("appel_a", {"nom": "A"})
    etat.enregistrer_proposition("appel_b", {"nom": "B"})
    with open(etat.FICHIER_PROPOSITIONS, encoding="utf-8") as f:
        assert json.load(f) == {"appel_a": {"nom": "A"}, "appel_b": {"nom": "B"}}
    assert not os.path.exists(etat.FICHIER_PROPOSITIONS + ".tmp")
