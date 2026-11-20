import importlib.util
import multiprocessing
import re
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool

from calls_debrief import etat, progression
from calls_debrief.config import (
    DIARISATION_DEVICE,
    DUREE_MIN_LOCUTEUR,
    EXTENSIONS_AUDIO,
    HF_TOKEN,
    MODELE_DIARISATION,
    MODELE_WHISPER,
)

# Chargement de FFmpeg pour la lecture des audios
try:
    import static_ffmpeg
    static_ffmpeg.add_paths()
except ImportError:
    pass

# Les modèles (MLX, PyTorch) ne sont importés que dans les processus enfants : le processus principal reste léger
WHISPER_DISPONIBLE = importlib.util.find_spec("mlx_whisper") is not None
PYANNOTE_DISPONIBLE = importlib.util.find_spec("pyannote") is not None and importlib.util.find_spec("torch") is not None

def _executer_isole(fonction, *args):
    """Exécute fonction(*args) dans un processus à part : toute sa mémoire est rendue au système à la fin.
    Si macOS le tue faute de mémoire, lève BrokenProcessPool au lieu de faire tomber tout le pipeline."""
    with ProcessPoolExecutor(max_workers=1, mp_context=multiprocessing.get_context("spawn")) as executeur:
        return executeur.submit(fonction, *args).result()

def _transcrire(chemin: str) -> list:
    """(Processus enfant) Segments Whisper [{start, end, text}]."""
    import sys

    import mlx_whisper
    import tqdm

    # La barre de progression de mlx-whisper (verbose=False) alimente aussi le pourcentage affiché dans l'app
    class Suivi(tqdm.tqdm):
        def update(self, n=1):
            resultat = super().update(n)
            progression.avancement(self.n, self.total)
            return resultat

    sys.modules["mlx_whisper.transcribe"].tqdm.tqdm = Suivi
    # Sans le texte précédent comme contexte, Whisper ne s'enferme plus dans une boucle ("Thank you. Thank you…")
    res = mlx_whisper.transcribe(chemin, path_or_hf_repo=MODELE_WHISPER, verbose=False, condition_on_previous_text=False)
    return [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in res["segments"]]

def _diariser(chemin: str) -> list:
    """(Processus enfant) Tours de parole pyannote [(début, fin, locuteur)]."""
    import numpy as np
    import torch
    from mlx_whisper.audio import SAMPLE_RATE, load_audio
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(MODELE_DIARISATION, token=HF_TOKEN)
    # Petits paquets : pic de mémoire bien plus bas, pour un temps de calcul à peine plus long
    pipeline.segmentation_batch_size = 8
    pipeline.embedding_batch_size = 8
    if DIARISATION_DEVICE == "mps" and torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    audio = np.array(load_audio(chemin))

    # Deux étapes longues : segmentation (~30 % du temps) puis empreintes vocales (~70 %)
    parts = {"segmentation": (0.0, 0.3), "embeddings": (0.3, 0.7)}
    def suivi(nom, artefact, file=None, total=None, completed=None):
        if nom in parts and total:
            debut, poids = parts[nom]
            progression.avancement(debut + poids * completed / total, 1)

    sortie = pipeline({"waveform": torch.from_numpy(audio)[None], "sample_rate": SAMPLE_RATE}, hook=suivi)
    # pyannote 4 : la version "exclusive" (un seul locuteur à la fois) s'aligne mieux sur Whisper
    annotation = getattr(sortie, "exclusive_speaker_diarization", sortie)
    return [(tour.start, tour.end, loc) for tour, _, loc in annotation.itertracks(yield_label=True)]

def diariser(chemin: str) -> list:
    """Tours de parole, ou [] si la diarisation est indisponible ou échoue."""
    if not PYANNOTE_DISPONIBLE or not HF_TOKEN:
        print("pyannote ou HF_TOKEN absent : transcription sans locuteurs.")
        return []
    try:
        return _executer_isole(_diariser, chemin)
    except BrokenProcessPool:
        print("Diarisation interrompue (mémoire insuffisante ?) : transcription sans locuteurs.")
    except Exception as e:
        # Accès refusé au modèle, réseau… : on ne jette pas la transcription Whisper déjà faite
        print(f"Diarisation impossible ({type(e).__name__}: {e}) : transcription sans locuteurs.")
    return []

# Phrases que Whisper invente sur les silences (héritées des sous-titres de vidéos de son entraînement)
PHRASES_PARASITES = ("sous-titres réalisés par", "amara.org", "sous-titrage st'", "merci d'avoir regardé cette vidéo")
# Une ponctuation collée au mot suivant ne termine pas la phrase : « Amara.org », « Node.js », « 3.5 »
_PHRASE = re.compile(r"(?:[^.!?…]|[.!?…](?=\w))+[.!?…]*")

def _cle(phrase: str) -> str:
    return re.sub(r"\W+", " ", phrase.lower()).strip()

def _sans_repetitions(phrases: list) -> list:
    """Une phrase répétée plusieurs fois de suite n'est gardée qu'une fois."""
    gardees = []
    for p in phrases:
        if not gardees or _cle(p) != _cle(gardees[-1]):
            gardees.append(p)
    return gardees

def nettoyer_texte(texte: str) -> str:
    """Retire d'un segment Whisper les phrases parasites et les répétitions en boucle.
    Un segment qui n'est qu'une même phrase répétée au moins 3 fois est une hallucination : il est vidé."""
    phrases = [p.strip() for p in _PHRASE.findall(texte) if p.strip()]
    phrases = [p for p in phrases if not any(x in p.lower() for x in PHRASES_PARASITES)]
    gardees = _sans_repetitions(phrases)
    if len(gardees) == 1 and len(phrases) >= 3:
        return ""
    return " ".join(gardees)

def nettoyer_segments(segments: list) -> list:
    return [dict(s, text=t) for s in segments if (t := nettoyer_texte(s["text"]))]

def fusionner(segments: list, tours: list) -> str:
    """Attribue à chaque segment Whisper le locuteur qui le recouvre le plus, et regroupe les répliques."""
    # Locuteurs qui ne parlent presque pas : le plus souvent une voix découpée en deux, ou un bruit pris pour une voix.
    # Leurs segments vont au locuteur suivant le plus présent (on garde toujours le locuteur principal).
    durees = {}
    for debut, fin, loc in tours:
        durees[loc] = durees.get(loc, 0) + fin - debut
    principal = max(durees, key=durees.get, default=None)
    mineurs = {loc for loc, d in durees.items() if d < DUREE_MIN_LOCUTEUR and loc != principal}

    repliques = []  # [locuteur, [phrases]]
    for seg in segments:
        recouvrements = {}
        for debut, fin, loc in tours:
            r = min(seg["end"], fin) - max(seg["start"], debut)
            if r > 0:
                recouvrements[loc] = recouvrements.get(loc, 0) + r
        texte = seg["text"].strip()
        # Aucune voix détectée par pyannote sur ce segment : texte inventé par Whisper sur un silence
        if not recouvrements or not texte:
            continue
        precedent = repliques[-1][0] if repliques else None
        candidats = {loc: r for loc, r in recouvrements.items() if loc not in mineurs}
        if candidats:
            loc = max(candidats, key=candidats.get)
        else:
            loc = precedent or max(recouvrements, key=recouvrements.get)
        if loc == precedent:
            repliques[-1][1].append(texte)
        else:
            repliques.append([loc, [texte]])
    # Un segment identique au précédent du même locuteur ("Thank you." puis "Thank you.") n'est gardé qu'une fois
    return "\n".join(f"{loc} : {' '.join(_sans_repetitions(textes))}" for loc, textes in repliques)

def obtenir_transcript(chemin: str, cle: str) -> str | None:
    """Retourne le texte du fichier (transcrit si audio), ou None s'il ne peut pas être traité."""
    if chemin.lower().endswith(EXTENSIONS_AUDIO):
        texte = etat.lire_transcript_cache(cle)
        if texte is not None:
            print("Transcription récupérée depuis le cache.")
            return texte
        segments = etat.lire_segments_cache(cle)
        if segments is None:
            if not WHISPER_DISPONIBLE:
                print("mlx_whisper non disponible, fichier ignoré.")
                return None
            print("Transcription locale via mlx-whisper (Apple Silicon)...")
            progression.etape("Transcription de l'audio")
            segments = _executer_isole(_transcrire, chemin)
            etat.ecrire_segments_cache(cle, segments)  # gardé même si pyannote plante ensuite
        else:
            print("Segments Whisper récupérés depuis le cache.")
        segments = nettoyer_segments(segments)
        print("Identification des locuteurs via pyannote...")
        progression.etape("Identification des locuteurs")
        tours = diariser(chemin)
        if not tours:
            # Pas de cache texte : au prochain lancement, seule la diarisation sera retentée
            return " ".join(s["text"].strip() for s in segments)
        texte = fusionner(segments, tours)
        etat.ecrire_transcript_cache(cle, texte)
        return texte

    with open(chemin, encoding="utf-8", errors="ignore") as f:
        texte = f.read()
    if chemin.lower().endswith(('.vtt', '.srt')):
        return nettoyer_sous_titres(texte)
    return texte

def nettoyer_sous_titres(texte: str) -> str:
    """Retire numéros, horodatages et balises d'un .vtt/.srt pour ne garder que les répliques."""
    lignes = []
    dans_note = False
    for ligne in texte.splitlines():
        ligne = ligne.strip().lstrip("﻿")
        if not ligne:
            dans_note = False
            continue
        if dans_note:
            continue
        if ligne.startswith(("NOTE", "STYLE", "REGION")):  # blocs non parlés, jusqu'à la ligne vide
            dans_note = True
            continue
        if ligne.startswith("WEBVTT") or "-->" in ligne or ligne.isdigit():
            continue
        ligne = re.sub(r"<v(?:\.[^ >]*)?\s+([^>]+)>", r"\1 : ", ligne)  # <v Nom> -> "Nom : "
        ligne = re.sub(r"<[^>]+>", "", ligne).strip()                   # autres balises (<c>, <i>, horodatages…)
        if ligne and (not lignes or lignes[-1] != ligne):              # doublons des sous-titres auto
            lignes.append(ligne)
    return "\n".join(lignes)
