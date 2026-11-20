import pytest

from calls_debrief.etapes import identification
from calls_debrief.etapes.identification import Identification, Locuteur, nettoyer_nom, proposer

TRANSCRIPT = """SPEAKER_00 : Bonjour, je suis Claire, responsable recrutement chez Acme.
SPEAKER_01 : Bonjour Claire.
SPEAKER_01 : Je suis étudiant en double diplôme et je cherche un stage en data.
"""


def reponse(**champs):
    valeurs = {
        "locuteurs": [Locuteur(etiquette="SPEAKER_00", indices="", nom=" Claire "),
                      Locuteur(etiquette="SPEAKER_01", indices="", nom="Alex"),
                      Locuteur(etiquette="SPEAKER_07", indices="", nom="Fantôme")],
        "nom_propose": "Acme - Claire (Recrutement)",
        "categorie": "entretien",
    }
    return Identification(**(valeurs | champs))


@pytest.mark.parametrize("brut, attendu", [
    ("Acme / Claire : RH", "Acme - Claire - RH"),
    ("  ..Nom   avec\tespaces  ", "Nom avec espaces"),
    ("", ""),
    ("x" * 200, "x" * 150),
])
def test_nettoyer_nom(brut, attendu):
    assert nettoyer_nom(brut) == attendu


def test_proposition_avec_reponse_du_modele(monkeypatch):
    monkeypatch.setattr(identification, "_identifier", lambda texte, etiquettes: reponse())
    proposition = proposer(TRANSCRIPT)
    assert proposition["nom"] == "Acme - Claire (Recrutement)"
    assert proposition["categorie"] == "entretien"
    # SPEAKER_07, absent du transcript, est ignoré ; les noms sont nettoyés des espaces
    assert proposition["locuteurs"] == [
        {"etiquette": "SPEAKER_00", "nom": "Claire",
         "extrait": "Bonjour, je suis Claire, responsable recrutement chez Acme."},
        {"etiquette": "SPEAKER_01", "nom": "Alex",
         "extrait": "Je suis étudiant en double diplôme et je cherche un stage en data."},  # la plus longue réplique
    ]


def test_nom_de_l_appel_nettoye(monkeypatch):
    monkeypatch.setattr(identification, "_identifier",
                        lambda texte, etiquettes: reponse(nom_propose="Acme / Claire"))
    assert proposer(TRANSCRIPT)["nom"] == "Acme - Claire"


def test_extrait_tronque_sur_un_mot():
    longue = "mot " * 60
    extrait = identification._extraits(f"SPEAKER_00 : {longue}")["SPEAKER_00"]
    assert extrait.endswith("…")
    assert len(extrait) <= identification.LONGUEUR_EXTRAIT + 1
    assert not extrait[:-1].endswith(" ")


def test_sans_aucun_modele_le_panneau_reste_avec_des_champs_vides():
    # conftest : ni Claude ni Gemini disponibles
    proposition = proposer(TRANSCRIPT)
    assert proposition["nom"] == "" and proposition["categorie"] == ""
    assert [loc["nom"] for loc in proposition["locuteurs"]] == ["", ""]


def test_sans_etiquettes_ni_reponse_rien_a_valider():
    assert proposer("Texte brut sans locuteurs.") is None


def test_echec_de_claude_passe_a_gemini(monkeypatch):
    from calls_debrief import claude, gemini

    def claude_en_panne(*args, **kwargs):
        raise RuntimeError("surcharge")

    monkeypatch.setattr(claude, "disponible", lambda: True)
    monkeypatch.setattr(claude, "generer_json", claude_en_panne)
    monkeypatch.setattr(identification, "GEMINI_API_KEY", "cle")
    monkeypatch.setattr(gemini, "generer_json", lambda prompt, schema: reponse(nom_propose="Via Gemini"))
    assert proposer(TRANSCRIPT)["nom"] == "Via Gemini"
