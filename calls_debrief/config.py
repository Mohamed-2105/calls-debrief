import os

from dotenv import load_dotenv

# Racine du projet (dossier parent du paquet) : .env et .etat/ y vivent
DOSSIER_PROJET = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(DOSSIER_PROJET, ".env"))

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
# Clé de l'API Claude (Anthropic) : Sonnet pour les résumés d'entretien, Haiku pour le reste ; sans elle, Gemini
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "").strip()
MODELE_ENTRETIEN = "claude-sonnet-5-5"   # ~5 à 8 centimes par résumé (réflexion d'effort moyen)
MODELE_LEGER = "claude-haiku-5-5"        # ~0,2 à 0,3 centime par appel
# Token Hugging Face (modèle pyannote à accès restreint) ; sans lui, transcription sans locuteurs
HF_TOKEN = os.getenv("HF_TOKEN")
# Prénom de la personne interviewée : sert à l'identifier dans la transcription et dans les résumés
NOM_CANDIDAT = os.getenv("CANDIDATE_NAME", "").strip()

# Dossier de travail contenant 01_A_Traiter, 02_Archives (anciens audios), 03_Transcripts et 04_Resumes
BASE_APPELS = os.path.expanduser(os.getenv("CALLS_FOLDER", "~/assistant-calls"))
DOSSIER_A_TRAITER = os.path.join(BASE_APPELS, "01_A_Traiter")
DOSSIER_ARCHIVES = os.path.join(BASE_APPELS, "02_Archives")
# Transcriptions (avec locuteurs si la diarisation a tourné)
DOSSIER_TRANSCRIPTS = os.path.join(BASE_APPELS, "03_Transcripts")
# Résumés IA générés depuis l'app (un par appel, même nom que le transcript, en Markdown)
DOSSIER_RESUMES = os.path.join(BASE_APPELS, "04_Resumes")
# Corbeille : appels supprimés depuis l'app (transcript + audio + cache), effacés pour de bon après N jours.
# Après modification, relancer `python installer_app.py` pour que l'app prenne la nouvelle valeur.
DOSSIER_CORBEILLE = os.path.join(DOSSIER_PROJET, "Corbeille")
DUREE_CORBEILLE_JOURS = 30

EXTENSIONS_AUDIO = ('.m4a', '.mp3', '.wav')
EXTENSIONS_TEXTE = ('.txt', '.vtt', '.srt')

MODELE_WHISPER = "mlx-community/whisper-large-v3-turbo"
MODELE_DIARISATION = "pyannote/speaker-diarization-community-1"
# En dessous de ce temps de parole (secondes) sur tout l'appel, un locuteur pyannote est considéré comme une fausse
# détection (voix découpée en deux, bruit) : ses répliques vont au locuteur voisin
DUREE_MIN_LOCUTEUR = 20
# Matériel pour pyannote : "cpu" (moins de mémoire) ou "mps" (GPU Apple, plus rapide mais plus gourmand)
DIARISATION_DEVICE = os.getenv("DIARISATION_DEVICE", "cpu").strip().lower()
MODELES_GEMINI = ["gemini-3.5-flash-lite", "gemini-3.8-flash"]
# Secours des résumés quand Gemini échoue : OVHcloud AI Endpoints (hébergé dans l'UE, API au format OpenAI).
# Sans clé : accès anonyme gratuit, 2 requêtes/min par modèle. Avec clé (projet Public Cloud payant) : 400/min.
OVH_URL = "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions"
OVH_CLE = os.getenv("OVH_AI_ENDPOINTS_ACCESS_TOKEN", "").strip()
MODELE_SECOURS = "Qwen3.5-397B-A17B"
