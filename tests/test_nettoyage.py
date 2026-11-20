import pytest

from calls_debrief import claude, nettoyage


def test_decouper_ne_coupe_jamais_une_replique(monkeypatch):
    monkeypatch.setattr(nettoyage, "TAILLE_MORCEAU", 50)
    lignes = [f"SPEAKER_0{i % 2} : réplique numéro {i}" for i in range(10)]
    morceaux = nettoyage.decouper("\n".join(lignes))
    assert len(morceaux) > 1
    assert "".join(morceaux).rstrip("\n") == "\n".join(lignes)
    for morceau in morceaux:
        assert all(ligne in lignes for ligne in morceau.rstrip("\n").split("\n"))


def test_decouper_texte_court_un_seul_morceau():
    assert nettoyage.decouper("A : bonjour") == ["A : bonjour\n"]


@pytest.mark.parametrize("net, rejete", [
    ("Claire : Bonjour, ça va bien ?", False),                       # petites corrections
    ("Claire : Bonjour.", True),                                     # beaucoup trop court
    ("Claire : Bonjour, ça va bien ? " + "bla " * 20, True),          # beaucoup trop long
    ("Claire : Bonjour, ça va ?\nPaul : ça va bien", True),          # locuteur inventé
])
def test_suspect(net, rejete):
    brut = "Claire : euh bonjour, ça va bien ?"
    assert bool(nettoyage._suspect(brut, net)) is rejete


def test_morceau_suspect_garde_la_version_brute(monkeypatch):
    monkeypatch.setattr(claude, "generer_texte", lambda *a, **k: ("Claire : Résumé.", 0.001, "modele"))
    brut = "Claire : euh alors donc je disais que le projet avance bien\n"
    texte, cout, rejete = nettoyage._nettoyer_morceau((1, brut, "", ""))
    assert (texte, rejete) == (brut, True)
    assert cout == 0.001


def test_echec_de_l_api_garde_la_version_brute(monkeypatch):
    def en_panne(*args, **kwargs):
        raise RuntimeError("réseau")

    monkeypatch.setattr(claude, "generer_texte", en_panne)
    brut = "Claire : bonjour\n"
    assert nettoyage._nettoyer_morceau((1, brut, "", "")) == (brut, 0.0, True)


def test_morceau_correct_est_nettoye(monkeypatch):
    monkeypatch.setattr(claude, "generer_texte",
                        lambda *a, **k: ("Claire : Le projet Claude Code avance bien.  ", 0.0002, "modele"))
    texte, _, rejete = nettoyage._nettoyer_morceau((1, "Claire : euh le projet cloud code avance bien\n", "", ""))
    assert (texte, rejete) == ("Claire : Le projet Claude Code avance bien.\n", False)


def test_chemin_brut():
    assert nettoyage.chemin_brut("/x/03_Transcripts/appel.txt") == "/x/03_Transcripts/.bruts/appel.txt"
