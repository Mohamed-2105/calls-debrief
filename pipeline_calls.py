import os
import traceback

from calls_debrief import etat, progression
from calls_debrief.config import DOSSIER_A_TRAITER, DOSSIER_TRANSCRIPTS, EXTENSIONS_AUDIO, EXTENSIONS_TEXTE, NOM_CANDIDAT
from calls_debrief.etapes.archivage import sauvegarder_transcript
from calls_debrief.etapes.identification import proposer
from calls_debrief.etapes.transcription import obtenir_transcript
from calls_debrief.etat import cle_fichier


def traiter_fichier(chemin: str):
    """Transcription seule : le transcript va dans 03_Transcripts, l'audio reste dans 01_A_Traiter."""
    texte_transcript = obtenir_transcript(chemin, cle_fichier(chemin))
    if texte_transcript is None:
        return
    if not texte_transcript.strip():
        print("Fichier vide ou inexploitable. Ignoré.")
        return

    # Le transcript garde ses étiquettes SPEAKER_XX : les noms ne sont appliqués qu'après validation dans l'app
    destination = sauvegarder_transcript(chemin, texte_transcript)
    print(f"Transcript de {os.path.basename(chemin)} enregistré dans {DOSSIER_TRANSCRIPTS}.")

    print("Préparation des noms à valider (Gemini)...")
    progression.etape("Identification des participants")
    proposition = proposer(texte_transcript)
    if proposition:
        etat.enregistrer_proposition(os.path.splitext(os.path.basename(destination))[0], proposition)
        noms = ", ".join(f"{loc['etiquette']} = {loc['nom'] or '?'}" for loc in proposition["locuteurs"])
        print(f"À valider dans l'app : {proposition['nom'] or '(nom à saisir)'} ; {noms}")

def lancer_pipeline_calls():
    if not NOM_CANDIDAT:
        raise SystemExit("CANDIDATE_NAME manquant dans .env : indique le prénom de la personne interviewée (ex. CANDIDATE_NAME=Alex).")

    os.makedirs(DOSSIER_A_TRAITER, exist_ok=True)
    os.makedirs(DOSSIER_TRANSCRIPTS, exist_ok=True)

    # L'audio reste dans 01_A_Traiter après transcription : on ne reprend que ceux qui n'ont pas encore de transcript
    fichiers = [f for f in os.listdir(DOSSIER_A_TRAITER) if f.lower().endswith(EXTENSIONS_AUDIO + EXTENSIONS_TEXTE)
                and not os.path.exists(os.path.join(DOSSIER_TRANSCRIPTS, os.path.splitext(f)[0] + ".txt"))]
    print(f"Fichiers à traiter : {fichiers}")

    echecs = []
    for fichier in fichiers:
        print(f"\nTraitement : {fichier}")
        progression.etape("Lecture du fichier", fichier=fichier)
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
