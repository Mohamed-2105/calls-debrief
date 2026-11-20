from calls_debrief.etapes.transcription import fusionner, nettoyer_segments, nettoyer_sous_titres, nettoyer_texte


def seg(debut, fin, texte):
    return {"start": debut, "end": fin, "text": texte}


# --- nettoyer_texte : hallucinations de Whisper ---

def test_phrase_repetee_de_suite_gardee_une_fois():
    assert nettoyer_texte("On commence. On commence. Et ensuite ?") == "On commence. Et ensuite ?"


def test_repetition_ignore_casse_et_ponctuation():
    assert nettoyer_texte("Bonjour ! bonjour. Ça va ?") == "Bonjour ! Ça va ?"


def test_segment_fait_d_une_seule_phrase_repetee_3_fois_est_vide():
    assert nettoyer_texte("Thank you. Thank you. Thank you.") == ""


def test_phrase_dite_deux_fois_reste():
    assert nettoyer_texte("Merci. Merci.") == "Merci."


def test_phrases_parasites_retirees():
    assert nettoyer_texte("Sous-titres réalisés par la communauté d'Amara.org") == ""
    assert nettoyer_texte("Super. Merci d'avoir regardé cette vidéo !") == "Super."


def test_point_colle_au_mot_suivant_ne_coupe_pas_la_phrase():
    texte = "On utilise Node.js et Claude 3.5. On utilise Node.js et Claude 3.5. Voilà."
    assert nettoyer_texte(texte) == "On utilise Node.js et Claude 3.5. Voilà."


def test_texte_normal_inchange():
    texte = "Je suis étudiant. Je cherche un stage en data, et vous ?"
    assert nettoyer_texte(texte) == texte


def test_nettoyer_segments_retire_les_segments_vides():
    segments = [seg(0, 2, "Bonjour."), seg(2, 4, "Thank you. Thank you. Thank you."), seg(4, 6, " ")]
    assert nettoyer_segments(segments) == [seg(0, 2, "Bonjour.")]


# --- fusionner : attribution des segments Whisper aux tours pyannote ---

def test_chaque_segment_va_au_locuteur_qui_le_recouvre_le_plus():
    tours = [(0, 30, "SPEAKER_00"), (30, 60, "SPEAKER_01")]
    segments = [seg(0, 10, "Bonjour."), seg(25, 40, "Ça va ?")]  # 5 s de 00, 10 s de 01
    assert fusionner(segments, tours) == "SPEAKER_00 : Bonjour.\nSPEAKER_01 : Ça va ?"


def test_segments_consecutifs_du_meme_locuteur_regroupes():
    tours = [(0, 30, "SPEAKER_00"), (30, 60, "SPEAKER_01")]
    segments = [seg(0, 5, "Bonjour."), seg(5, 10, "Je suis Claire."), seg(35, 40, "Enchanté.")]
    assert fusionner(segments, tours) == "SPEAKER_00 : Bonjour. Je suis Claire.\nSPEAKER_01 : Enchanté."


def test_segment_sans_voix_detectee_est_retire():
    tours = [(0, 30, "SPEAKER_00"), (40, 70, "SPEAKER_01")]
    segments = [seg(0, 5, "Bonjour."), seg(31, 39, "Texte inventé sur un silence."), seg(45, 50, "Salut.")]
    assert fusionner(segments, tours) == "SPEAKER_00 : Bonjour.\nSPEAKER_01 : Salut."


def test_locuteur_mineur_rattache_au_locuteur_present():
    # SPEAKER_02 ne parle que 5 s sur l'appel (< DUREE_MIN_LOCUTEUR) : fausse détection
    tours = [(0, 40, "SPEAKER_00"), (40, 45, "SPEAKER_02"), (45, 90, "SPEAKER_01")]
    segments = [seg(30, 39, "Première partie,"), seg(40, 45, "suite de la phrase."), seg(50, 60, "Réponse.")]
    assert fusionner(segments, tours) == "SPEAKER_00 : Première partie, suite de la phrase.\nSPEAKER_01 : Réponse."


def test_locuteur_principal_garde_meme_sous_le_seuil():
    tours = [(0, 5, "SPEAKER_00")]  # appel très court : le seul locuteur n'est jamais écarté
    assert fusionner([seg(0, 5, "Allô ?")], tours) == "SPEAKER_00 : Allô ?"


def test_segment_identique_au_precedent_du_meme_locuteur_garde_une_fois():
    tours = [(0, 60, "SPEAKER_00")]
    segments = [seg(0, 2, "Thank you."), seg(2, 4, "Thank you."), seg(4, 6, "Bye.")]
    assert fusionner(segments, tours) == "SPEAKER_00 : Thank you. Bye."


def test_sans_tours_rien_n_est_garde():
    assert fusionner([seg(0, 5, "Bonjour.")], []) == ""


# --- nettoyer_sous_titres : .vtt / .srt ---

def test_vtt():
    vtt = """WEBVTT

NOTE ceci n'est pas parlé
et cela non plus

1
00:00:01.000 --> 00:00:03.000
<v Claire Martin>Bonjour <i>à tous</i>

2
00:00:03.000 --> 00:00:05.000
<v.recruteur Paul>Salut Claire
"""
    assert nettoyer_sous_titres(vtt) == "Claire Martin : Bonjour à tous\nPaul : Salut Claire"


def test_srt_doublons_consecutifs_retires():
    srt = """1
00:00:01,000 --> 00:00:02,000
On y va

2
00:00:02,000 --> 00:00:03,000
On y va

3
00:00:03,000 --> 00:00:04,000
C'est parti
"""
    assert nettoyer_sous_titres(srt) == "On y va\nC'est parti"


def test_bom_en_tete_ignore():
    assert nettoyer_sous_titres("﻿WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBonjour") == "Bonjour"
