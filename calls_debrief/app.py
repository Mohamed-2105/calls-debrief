"""Construit et installe l'app de la barre des menus dans ~/Applications/Calls Debrief.app."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

from calls_debrief import progression
from calls_debrief.config import (
    DOSSIER_A_TRAITER,
    DOSSIER_ARCHIVES,
    DOSSIER_CORBEILLE,
    DOSSIER_PROJET,
    DOSSIER_RESUMES,
    DOSSIER_TRANSCRIPTS,
    DUREE_CORBEILLE_JOURS,
    NOM_CANDIDAT,
)
from calls_debrief.enregistrement import DOSSIER_BRUTS, DOSSIER_OUTILS, compiler
from calls_debrief.etat import DOSSIER_CACHE_TRANSCRIPTS, DOSSIER_ETAT, FICHIER_PROFIL, FICHIER_PROMPTS, FICHIER_PROPOSITIONS
from calls_debrief.resume import PROMPTS_DEFAUT

NOM_APP = "Calls Debrief"
EXECUTABLE = "CallsDebrief"
IDENTIFIANT = "local.calls-debrief.app"
APP = os.path.expanduser(f"~/Applications/{NOM_APP}.app")
# Certificat auto-signé du trousseau de session (voir README) ; pas besoin qu'il soit marqué fiable
CERTIFICAT_SIGNATURE = "Calls Debrief"


def identite_signature() -> str:
    """Empreinte SHA-1 du certificat CERTIFICAT_SIGNATURE, ou « - » (signature ad hoc) s'il est absent."""
    sortie = subprocess.run(["security", "find-identity", "-p", "codesigning"],
                            capture_output=True, text=True).stdout
    for ligne in sortie.splitlines():
        morceaux = ligne.split()
        if len(morceaux) >= 3 and morceaux[0].endswith(")") and f'"{CERTIFICAT_SIGNATURE}"' in ligne:
            return morceaux[1]
    return "-"


def creer_icone(destination: str):
    """Dessine l'icône (outils/icone) et la convertit en .icns."""
    binaire = os.path.join(DOSSIER_ETAT, "bin", "icone")
    compiler([os.path.join(DOSSIER_OUTILS, "icone", "main.swift")], binaire)
    with tempfile.TemporaryDirectory() as dossier:
        iconset = os.path.join(dossier, "AppIcon.iconset")
        subprocess.run([binaire, iconset], check=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", destination], check=True)

def installer():
    python = os.path.join(DOSSIER_PROJET, ".venv", "bin", "python3")
    if not os.path.exists(python):
        python = sys.executable

    subprocess.run(["pkill", "-x", EXECUTABLE], check=False)  # remplace une version déjà lancée
    if os.path.exists(APP):
        shutil.rmtree(APP)
    contenu = os.path.join(APP, "Contents")
    os.makedirs(os.path.join(contenu, "MacOS"))
    os.makedirs(os.path.join(contenu, "Resources"))

    print("Compilation de l'app...")
    dossier_app = os.path.join(DOSSIER_OUTILS, "app")
    sources_app = sorted(os.path.join(dossier_app, f) for f in os.listdir(dossier_app) if f.endswith(".swift"))
    compiler([os.path.join(DOSSIER_OUTILS, "commun", "Capture.swift"), *sources_app],
             os.path.join(contenu, "MacOS", EXECUTABLE))

    creer_icone(os.path.join(contenu, "Resources", "AppIcon.icns"))
    os.makedirs(DOSSIER_RESUMES, exist_ok=True)

    with open(os.path.join(contenu, "Info.plist"), "wb") as f:
        plistlib.dump({
            "CFBundleIdentifier": IDENTIFIANT,
            "CFBundleName": NOM_APP,
            "CFBundleDisplayName": NOM_APP,
            "CFBundleExecutable": EXECUTABLE,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": True,  # icône dans la barre des menus seulement, pas dans le Dock
            "NSMicrophoneUsageDescription": "Enregistrer ta voix pendant les entretiens.",
            # Chemins du projet, lus par l'app
            "CDProjet": DOSSIER_PROJET,
            "CDPython": python,
            "CDBruts": DOSSIER_BRUTS,
            "CDATraiter": DOSSIER_A_TRAITER,
            "CDTranscripts": DOSSIER_TRANSCRIPTS,
            "CDResumes": DOSSIER_RESUMES,
            "CDArchives": DOSSIER_ARCHIVES,
            "CDCache": DOSSIER_CACHE_TRANSCRIPTS,
            "CDCorbeille": DOSSIER_CORBEILLE,
            "CDDureeCorbeille": DUREE_CORBEILLE_JOURS,
            "CDJournaux": os.path.join(DOSSIER_ETAT, "journaux"),
            "CDProgression": progression.FICHIER,
            "CDPropositions": FICHIER_PROPOSITIONS,
            "CDPrompts": FICHIER_PROMPTS,          # prompts des résumés modifiés dans l'app
            "CDProfil": FICHIER_PROFIL,            # ton profil, ajouté au contexte des résumés
            "CDPromptsDefaut": PROMPTS_DEFAUT,     # pour « Rétablir le prompt par défaut »
            "CDCandidat": NOM_CANDIDAT,  # proposé en premier dans les listes de noms du panneau de validation
        }, f)

    # Signature locale : nécessaire pour que macOS mémorise les autorisations (micro, audio système).
    # Avec le certificat « Calls Debrief » du trousseau, l'app garde la même identité d'une compilation
    # à l'autre et les autorisations survivent ; sans lui (signature ad hoc), il faut les redonner à chaque fois.
    identite = identite_signature()
    if identite == "-":
        print(f"Certificat « {CERTIFICAT_SIGNATURE} » introuvable : signature ad hoc, "
              "macOS redemandera les autorisations après chaque installation.")
    subprocess.run(["codesign", "--force", "--sign", identite, APP], check=True)
    # Le Finder et les notifications gardent l'ancienne icône en cache sans ce signal
    subprocess.run(["touch", APP], check=False)
    subprocess.run(["open", APP], check=True)
    print(f"App installée et lancée : {APP}")
    print("Pour l'ouvrir depuis le Finder : Applications (de ton dossier perso) > Calls Debrief, ou Spotlight.")
