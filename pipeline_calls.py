import os
import traceback

from calls_debrief.config import DOSSIER_A_TRAITER, DOSSIER_TRANSCRIPTS, EXTENSIONS_AUDIO, EXTENSIONS_TEXTE, NOM_CANDIDAT
from calls_debrief.etat import cle_fichier
from calls_debrief.etapes.transcription import obtenir_transcript
from calls_debrief.etapes.archivage import sauvegarder_transcript

def traiter_fichier(chemin: str):
    """Transcription seule : le transcript va dans 03_Transcripts, l'audio reste dans 01_A_Traiter."""
    texte_transcript = obtenir_transcript(chemin, cle_fichier(chemin))
    if texte_transcript is None:
        return
    if not texte_transcript.strip():
        print("Fichier vide ou inexploitable. Ignoré.")
        return
    sauvegarder_transcript(chemin, texte_transcript)
    print(f"Transcript de {os.path.basename(chemin)} enregistré dans {DOSSIER_TRANSCRIPTS}.")

def lancer_pipeline_calls():
    if not NOM_CANDIDAT:
        raise SystemExit("CANDIDATE_NAME manquant dans .env : indique le prénom de la personne interviewée (ex. CANDIDATE_NAME=Alex).")

    os.makedirs(DOSSIER_A_TRAITER, exist_ok=True)
    os.makedirs(DOSSIER_TRANSCRIPTS, exist_ok=True)

    fichiers = [f for f in os.listdir(DOSSIER_A_TRAITER) if f.lower().endswith(EXTENSIONS_AUDIO + EXTENSIONS_TEXTE)]
    print(f"Fichiers à traiter : {fichiers}")

    echecs = []
    for fichier in fichiers:
        print(f"\nTraitement : {fichier}")
        try:
            traiter_fichier(os.path.join(DOSSIER_A_TRAITER, fichier))
        except Exception:
            print(f"[ÉCHEC] {fichier} laissé dans {DOSSIER_A_TRAITER} :")
            traceback.print_exc()
            echecs.append(fichier)

    if echecs:
        print(f"\n{len(echecs)} fichier(s) en échec : {echecs}")

if __name__ == "__main__":
    lancer_pipeline_calls()
