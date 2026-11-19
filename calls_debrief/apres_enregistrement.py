"""Lancé par l'app de la barre des menus à la fin d'un enregistrement : mixage, puis transcription."""
from calls_debrief import progression
from calls_debrief.enregistrement import finaliser_en_attente
from pipeline_calls import lancer_pipeline_calls

if __name__ == "__main__":
    try:
        progression.etape("Préparation de l'enregistrement", fichier="")
        finaliser_en_attente()
        lancer_pipeline_calls()
    finally:
        progression.effacer()
