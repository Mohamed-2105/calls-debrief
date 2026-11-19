"""Secours des résumés quand Gemini est indisponible : OVHcloud AI Endpoints (API au format OpenAI, hébergée dans l'UE).

Fonctionne sans clé (accès anonyme, 2 requêtes/min par modèle) ; OVH_AI_ENDPOINTS_ACCESS_TOKEN dans .env lève la limite."""
import re
import time

import httpx

from calls_debrief.config import MODELE_SECOURS, OVH_CLE, OVH_URL

NB_TENTATIVES = 2
ATTENTE = 65  # la limite anonyme est par minute

def generer_texte(prompt: str, statut=None) -> str:
    """Réponse texte du modèle de secours. Lève RuntimeError en cas d'échec."""
    statut = statut or (lambda _texte: None)
    entetes = {"Authorization": f"Bearer {OVH_CLE}"} if OVH_CLE else {}
    corps = {"model": MODELE_SECOURS, "messages": [{"role": "user", "content": prompt}],
             "temperature": 0.3, "max_tokens": 16000}
    derniere_erreur = None
    for tentative in range(1, NB_TENTATIVES + 1):
        statut(f"Essai avec OVHcloud ({MODELE_SECOURS})" + (f", essai {tentative}/{NB_TENTATIVES}" if tentative > 1 else "")
               + " : environ 1 min…")
        try:
            reponse = httpx.post(OVH_URL, json=corps, headers=entetes, timeout=600)
            if reponse.status_code == 200:
                texte = (reponse.json()["choices"][0]["message"].get("content") or "").strip()
                # Certains modèles laissent leur raisonnement entre balises <think>
                texte = re.sub(r"<think>.*?</think>", "", texte, flags=re.S).strip()
                if texte:
                    return texte
                derniere_erreur = "réponse vide"
            elif reponse.status_code in (429, 500, 502, 503, 504):
                derniere_erreur = f"HTTP {reponse.status_code}"
            else:  # clé invalide, requête refusée : inutile de réessayer
                raise RuntimeError(f"OVHcloud : HTTP {reponse.status_code} {reponse.text[:200]}")
        except httpx.TransportError as e:
            derniere_erreur = str(e) or type(e).__name__
        print(f"OVHcloud : échec ({derniere_erreur}).")
        if tentative < NB_TENTATIVES:
            statut(f"OVHcloud indisponible ({derniere_erreur}) : nouvel essai dans {ATTENTE} s…")
            time.sleep(ATTENTE)
    raise RuntimeError(f"Échec du secours OVHcloud : {derniere_erreur}")
