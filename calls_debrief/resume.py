"""Résumé IA d'un appel, lancé depuis l'app (bouton « Résumé IA ») :

    python -m calls_debrief.resume --transcript <03_Transcripts/nom.txt> --format pro [--prompt-stdin]

Le prompt de base du format vient de .etat/prompts.json (modifié dans l'app, fenêtre Prompts), sinon de
prompts.json à la racine du projet (tes prompts par défaut, ignoré par git), sinon de prompts.example.json. Avec --prompt-stdin, le prompt lu sur l'entrée standard le remplace pour ce résumé seulement.
Le profil écrit dans l'app (.etat/profil.md) est ajouté au contexte.
Modèles : Claude Sonnet pour les entretiens, Claude Haiku pour les autres formats (si ANTHROPIC_API_KEY),
puis Gemini, puis OVHcloud en secours.
Le résumé (Markdown) est écrit dans 04_Resumes/<nom>.md et remplace le précédent."""
import argparse
import json
import os
import sys
from datetime import datetime

from calls_debrief.config import (
    DOSSIER_PROJET,
    DOSSIER_RESUMES,
    GEMINI_API_KEY,
    MODELE_ENTRETIEN,
    MODELE_LEGER,
    MODELE_SECOURS,
    NOM_CANDIDAT,
)
from calls_debrief.etat import FICHIER_PROFIL, FICHIER_PROMPTS

TITRES = {"entretien": "Entretien", "pro": "Call pro", "perso": "Call perso", "neutre": "Neutre"}

def charger_prompts_defaut() -> dict:
    """Prompts par défaut de chaque format : prompts.json (perso, ignoré par git), sinon prompts.example.json.
    Un format absent du fichier perso garde celui de l'exemple."""
    with open(os.path.join(DOSSIER_PROJET, "prompts.example.json"), encoding="utf-8") as f:
        prompts = json.load(f)
    try:
        with open(os.path.join(DOSSIER_PROJET, "prompts.json"), encoding="utf-8") as f:
            perso = json.load(f)
    except FileNotFoundError:
        return prompts
    prompts.update({k: v for k, v in perso.items() if k in prompts and v.strip()})
    return prompts

PROMPTS_DEFAUT = charger_prompts_defaut()

CONSIGNES = """
---
CONTEXTE ET FORMAT (s'appliquent quelle que soit la consigne ci-dessus) :
- Ci-dessous, la transcription automatique d'un appel enregistré par {nom}. « Je », « moi », « mon », dans la consigne, désignent {nom}.
- Des étiquettes SPEAKER_00, SPEAKER_01… désignent des voix détectées automatiquement mais pas encore identifiées : déduis du contexte qui parle quand c'est possible. La transcription peut contenir des erreurs (noms propres surtout).
- Réponds en Markdown simple : titres ## et ###, listes avec -, **gras** si utile. Pas de bloc de code, pas de tableau, pas de préambule (« Voici le résumé… »).
- Rédige en français, sauf les citations, qui gardent leur langue d'origine.
- N'invente rien : rapporte uniquement ce qui est dit dans l'appel.
{profil}
Transcription :
{texte}"""

def prompts_modifies() -> dict:
    try:
        with open(FICHIER_PROMPTS, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def lire_profil() -> str:
    try:
        with open(FICHIER_PROFIL, encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""

def prompt_de_base(format: str) -> str:
    modifie = (prompts_modifies().get(format) or "").strip()
    return modifie or PROMPTS_DEFAUT[format]

# Préfixe des lignes d'étape du journal : l'app affiche la dernière pendant la génération
PREFIXE_STATUT = "STATUT: "

def statut(texte: str):
    print(PREFIXE_STATUT + texte, flush=True)

def construire_prompt(texte: str, consigne: str) -> str:
    nom = NOM_CANDIDAT or "la personne qui enregistre"
    profil = lire_profil()
    bloc_profil = (f"\nPROFIL DE {nom.upper()} (écrit par {nom} : sers-t'en pour rendre l'analyse pertinente pour lui, "
                   f"sans le résumer ni le recopier) :\n{profil}\n") if profil else ""
    return consigne.strip() + "\n" + CONSIGNES.format(nom=nom, texte=texte, profil=bloc_profil)

def resumer(texte: str, consigne: str, format: str) -> tuple:
    """(résumé, source : modèle et coût) : Claude (Sonnet pour un entretien, Haiku sinon), puis Gemini, puis OVHcloud."""
    prompt = construire_prompt(texte, consigne)
    resume, source = None, None

    from calls_debrief import claude
    if claude.disponible():
        modele = MODELE_ENTRETIEN if format == "entretien" else MODELE_LEGER
        # Entretien : réflexion d'effort moyen (c'est là qu'elle sert) ; le reste est de la mise en forme
        effort, limite = ("medium", 12000) if format == "entretien" else ("low", 8000)
        statut(f"Génération avec {claude.nom(modele)}…")
        try:
            resume, cout, servi = claude.generer_texte(prompt, modele, effort, limite, tache=f"résumé {format}")
            source = claude.nom(servi) + (f" · {cout:.2f} $".replace(".", ",") if cout is not None else "")
        except Exception as e:
            print(f"Claude : échec ({e}).")
            statut("Claude indisponible → essai avec Gemini…")

    if resume is None and GEMINI_API_KEY:
        from calls_debrief import gemini  # importe google-genai seulement à l'usage
        try:
            # Un seul essai par modèle : en cas de surcharge, OVHcloud répond plus vite que les nouveaux essais
            resume, source = gemini.generer_texte(prompt, statut=statut, tentatives=1), gemini.dernier_modele
        except RuntimeError as e:
            print(e)
            statut("Gemini indisponible → essai avec OVHcloud…")
    if resume is None:
        from calls_debrief.secours import generer_texte
        resume, source = generer_texte(prompt, statut=statut), f"OVHcloud {MODELE_SECOURS}"
    # Certains modèles entourent quand même la réponse d'un bloc ```markdown
    if resume.startswith("```"):
        resume = resume.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return resume, source

def ecrire_resume(nom: str, entete: str, resume: str) -> str:
    os.makedirs(DOSSIER_RESUMES, exist_ok=True)
    destination = os.path.join(DOSSIER_RESUMES, nom + ".md")
    temporaire = os.path.join(DOSSIER_RESUMES, "." + nom + ".md.tmp")  # caché : l'app ne le voit pas
    with open(temporaire, "w", encoding="utf-8") as f:
        f.write(f"{entete}\n\n{resume}\n")
    os.replace(temporaire, destination)  # l'app ne lit jamais un résumé à moitié écrit
    return destination

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--transcript", help="Chemin du transcript (.txt)")
    parser.add_argument("--format", choices=sorted(PROMPTS_DEFAUT), default="neutre")
    parser.add_argument("--prompt-stdin", action="store_true", help="Lit sur l'entrée standard un prompt qui remplace celui du format")
    parser.add_argument("--defauts", action="store_true", help="Affiche les prompts par défaut en JSON")
    args = parser.parse_args()

    if args.defauts:
        print(json.dumps(PROMPTS_DEFAUT, ensure_ascii=False, indent=2))
        return
    if not args.transcript:
        parser.error("--transcript est requis")

    with open(args.transcript, encoding="utf-8") as f:
        texte = f.read()
    if not texte.strip():
        sys.exit("Le transcript est vide.")

    personnalise = sys.stdin.read().strip() if args.prompt_stdin else ""
    consigne = personnalise or prompt_de_base(args.format)
    nom = os.path.splitext(os.path.basename(args.transcript))[0]
    print(f"Résumé de {nom} (format {TITRES[args.format]}{', prompt personnalisé' if personnalise else ''})...")

    try:
        resume, source = resumer(texte, consigne, args.format)
    except Exception as e:
        print(e)
        sys.exit("Échec de tous les modèles (Claude, Gemini, OVHcloud) : réessaie dans quelques minutes (détails dans le journal).")

    date = datetime.now().strftime("%d/%m/%Y %H:%M")
    entete = (f"_Format : {TITRES[args.format]}{' (prompt personnalisé)' if personnalise else ''}"
              f" · {source} · généré le {date}_")
    print(f"Résumé enregistré : {ecrire_resume(nom, entete, resume)}")

if __name__ == "__main__":
    main()
