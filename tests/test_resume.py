import json

import pytest

from calls_debrief import claude, gemini, resume, secours


@pytest.fixture
def sans_profil_ni_prompts(monkeypatch, tmp_path):
    monkeypatch.setattr(resume, "FICHIER_PROFIL", str(tmp_path / "profil.md"))
    monkeypatch.setattr(resume, "FICHIER_PROMPTS", str(tmp_path / "prompts.json"))
    return tmp_path


def test_prompts_par_defaut_couvrent_tous_les_formats():
    assert set(resume.PROMPTS_DEFAUT) == set(resume.TITRES)
    assert all(p.strip() for p in resume.PROMPTS_DEFAUT.values())


def test_prompt_modifie_dans_l_app_prioritaire(sans_profil_ni_prompts):
    (sans_profil_ni_prompts / "prompts.json").write_text(json.dumps({"pro": "Mon prompt pro", "perso": "  "}))
    assert resume.prompt_de_base("pro") == "Mon prompt pro"
    assert resume.prompt_de_base("perso") == resume.PROMPTS_DEFAUT["perso"]  # vide : défaut


def test_construire_prompt_sans_profil(sans_profil_ni_prompts):
    prompt = resume.construire_prompt("SPEAKER_00 : Bonjour.", "Résume ce call.")
    assert prompt.startswith("Résume ce call.\n")
    assert prompt.endswith("Transcription :\nSPEAKER_00 : Bonjour.")
    assert "PROFIL" not in prompt


def test_construire_prompt_avec_profil(sans_profil_ni_prompts):
    (sans_profil_ni_prompts / "profil.md").write_text("Étudiant, cherche un stage en data.\n")
    assert "Étudiant, cherche un stage en data." in resume.construire_prompt("texte", "Consigne")


def test_claude_en_premier(sans_profil_ni_prompts, monkeypatch):
    appels = []
    monkeypatch.setattr(claude, "disponible", lambda: True)
    monkeypatch.setattr(claude, "generer_texte",
                        lambda prompt, modele, *a, **k: appels.append(modele) or ("## Résumé", 0.05, modele))
    texte, source = resume.resumer("transcript", "consigne", "entretien")
    assert texte == "## Résumé"
    assert appels == [resume.MODELE_ENTRETIEN]  # Sonnet pour un entretien
    assert source == "Claude Sonnet 5.5 · 0,05 $"
    resume.resumer("transcript", "consigne", "pro")
    assert appels[-1] == resume.MODELE_LEGER     # Haiku pour le reste


def test_repli_claude_puis_gemini_puis_ovh(sans_profil_ni_prompts, monkeypatch):
    def en_panne(*args, **kwargs):
        raise RuntimeError("indisponible")

    monkeypatch.setattr(claude, "disponible", lambda: True)
    monkeypatch.setattr(claude, "generer_texte", en_panne)
    monkeypatch.setattr(resume, "GEMINI_API_KEY", "cle")
    monkeypatch.setattr(gemini, "generer_texte", en_panne)
    monkeypatch.setattr(secours, "generer_texte", lambda prompt, statut=None: "```markdown\n## Via OVH\n```")
    texte, source = resume.resumer("transcript", "consigne", "neutre")
    assert texte == "## Via OVH"  # le bloc ```markdown est retiré
    assert source.startswith("OVHcloud")


def test_sans_claude_gemini_repond(sans_profil_ni_prompts, monkeypatch):
    monkeypatch.setattr(resume, "GEMINI_API_KEY", "cle")
    monkeypatch.setattr(gemini, "generer_texte", lambda prompt, **k: "## Via Gemini")
    monkeypatch.setattr(gemini, "dernier_modele", "gemini-test", raising=False)
    assert resume.resumer("transcript", "consigne", "pro") == ("## Via Gemini", "gemini-test")
