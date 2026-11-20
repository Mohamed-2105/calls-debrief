"""Enregistrement d'un entretien en visio : son de l'ordi + micro, mixés dans 01_A_Traiter.

Les pistes brutes sont écrites dans .etat/enregistrements/<horodatage>/ par l'outil Swift (terminal ou app de la
barre des menus). Un dossier contenant debuts.json est complet et peut être mixé."""
import json
import os
import shutil
import signal
import subprocess
from datetime import datetime

from calls_debrief.config import DOSSIER_A_TRAITER, DOSSIER_PROJET
from calls_debrief.etat import DOSSIER_ETAT

DOSSIER_OUTILS = os.path.join(DOSSIER_PROJET, "outils")
SOURCES_CLI = [os.path.join(DOSSIER_OUTILS, "commun", "Capture.swift"), os.path.join(DOSSIER_OUTILS, "enregistreur", "main.swift")]
BINAIRE = os.path.join(DOSSIER_ETAT, "bin", "enregistreur")
DOSSIER_BRUTS = os.path.join(DOSSIER_ETAT, "enregistrements")

def compiler(sources: list, sortie: str, options: tuple = ()):
    if not shutil.which("swiftc"):
        raise SystemExit("swiftc introuvable : installe les outils de développement avec `xcode-select --install`.")
    os.makedirs(os.path.dirname(sortie), exist_ok=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "5", *options, *sources, "-o", sortie], check=True)

def compiler_si_besoin():
    """Compile l'outil en ligne de commande au premier lancement, ou quand son code a changé."""
    if os.path.exists(BINAIRE) and os.path.getmtime(BINAIRE) >= max(map(os.path.getmtime, SOURCES_CLI)):
        return
    print("Compilation de l'enregistreur (une seule fois)...")
    compiler(SOURCES_CLI, BINAIRE)

def _ffmpeg() -> str:
    try:
        import static_ffmpeg
        static_ffmpeg.add_paths()
    except ImportError:
        pass
    chemin = shutil.which("ffmpeg")
    if not chemin:
        raise SystemExit("ffmpeg introuvable (pip install static-ffmpeg).")
    return chemin

def mixer(dossier_bruts: str, sortie: str):
    """Mixe systeme.m4a et micro.m4a en une piste mono, alignées sur leur premier son."""
    pistes = [p for p in ("systeme", "micro") if os.path.exists(os.path.join(dossier_bruts, f"{p}.m4a"))]
    if not pistes:
        raise RuntimeError("Aucun son enregistré.")
    try:
        with open(os.path.join(dossier_bruts, "debuts.json"), encoding="utf-8") as f:
            debuts = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        debuts = {}
    origine = min((debuts[p] for p in pistes if p in debuts), default=0)

    commande = [_ffmpeg(), "-y", "-loglevel", "error"]
    filtres = []
    for i, piste in enumerate(pistes):
        commande += ["-i", os.path.join(dossier_bruts, f"{piste}.m4a")]
        decalage_ms = round((debuts.get(piste, origine) - origine) * 1000)
        filtres.append(f"[{i}:a]adelay=delays={decalage_ms}:all=1[a{i}]")
    entrees = "".join(f"[a{i}]" for i in range(len(pistes)))
    filtres.append(f"{entrees}amix=inputs={len(pistes)}:duration=longest:normalize=0,aformat=channel_layouts=mono[sortie]")

    # Nom temporaire sans extension audio : le pipeline ne prend pas un fichier à moitié écrit
    temporaire = sortie + ".partiel"
    commande += ["-filter_complex", ";".join(filtres), "-map", "[sortie]", "-c:a", "aac", "-b:a", "96k", "-f", "mp4", temporaire]
    subprocess.run(commande, check=True)
    os.replace(temporaire, sortie)

def finaliser(dossier_bruts: str) -> str:
    """Mixe un enregistrement complet vers 01_A_Traiter/appel_<horodatage>.m4a, puis supprime les pistes brutes."""
    os.makedirs(DOSSIER_A_TRAITER, exist_ok=True)
    nom = os.path.basename(dossier_bruts.rstrip(os.sep))
    sortie, n = os.path.join(DOSSIER_A_TRAITER, f"appel_{nom}.m4a"), 2
    while os.path.exists(sortie):  # deux enregistrements dans la même minute
        sortie, n = os.path.join(DOSSIER_A_TRAITER, f"appel_{nom}_{n}.m4a"), n + 1
    mixer(dossier_bruts, sortie)
    shutil.rmtree(dossier_bruts)  # en cas d'échec du mixage, les pistes brutes restent dans .etat/enregistrements
    return sortie

def finaliser_en_attente() -> list:
    """Mixe tous les enregistrements complets (debuts.json présent) ; ceux en cours sont laissés tels quels."""
    if not os.path.isdir(DOSSIER_BRUTS):
        return []
    sorties = []
    for nom in sorted(os.listdir(DOSSIER_BRUTS)):
        dossier = os.path.join(DOSSIER_BRUTS, nom)
        if not os.path.exists(os.path.join(dossier, "debuts.json")):
            continue
        try:
            sorties.append(finaliser(dossier))
            print(f"Enregistrement prêt : {sorties[-1]}")
        except Exception as e:
            print(f"[ÉCHEC] Mixage de {dossier} : {e}")
    return sorties

def enregistrer():
    """Enregistrement depuis le terminal, jusqu'à Ctrl+C."""
    compiler_si_besoin()
    dossier_bruts = os.path.join(DOSSIER_BRUTS, datetime.now().strftime("%Y-%m-%d_%Hh%M"))

    processus = subprocess.Popen([BINAIRE, dossier_bruts], stdout=subprocess.PIPE, text=True)
    try:
        if processus.stdout.readline().strip() != "PRET":
            processus.wait()
            raise SystemExit(f"L'enregistreur n'a pas pu démarrer (code {processus.returncode}).")
        print("Enregistrement en cours (son de l'ordi + micro). Ctrl+C pour arrêter.")
        processus.wait()
    except KeyboardInterrupt:
        # Le terminal envoie déjà Ctrl+C à l'enregistreur ; on le renvoie au cas où, puis on attend qu'il finalise
        processus.send_signal(signal.SIGINT)
        print("\nArrêt, finalisation des fichiers...")
        processus.wait(timeout=60)

    print(f"Enregistrement prêt : {finaliser(dossier_bruts)}")
    print("Lance `python pipeline_calls.py` pour le transcrire.")
