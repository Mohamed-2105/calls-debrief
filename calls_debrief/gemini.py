"""Appels à Gemini avec réponse JSON structurée : nouveaux essais si besoin, puis repli sur le modèle suivant."""
import time

import httpx
from google import genai
from google.genai import errors

from calls_debrief.config import GEMINI_API_KEY, MODELES_GEMINI

NB_TENTATIVES = 3
_client = None
dernier_modele = None  # modèle qui a produit la dernière réponse réussie

class ReponseInvalide(Exception):
    """Gemini a répondu, mais sans JSON exploitable."""

def _erreur_temporaire(e: Exception) -> bool:
    """Vrai si un nouvel essai sur le même modèle a des chances de réussir."""
    if isinstance(e, errors.APIError):
        return e.code == 429 or e.code >= 500
    # Réseau coupé, timeout ou réponse tronquée : on réessaie
    return isinstance(e, (httpx.TransportError, ReponseInvalide))

def _generer(prompt: str, config: dict, extraire, modeles: list, statut=None, tentatives: int = NB_TENTATIVES):
    """Appelle Gemini en essayant les modèles dans l'ordre ; extraire(response) donne le résultat ou lève
    ReponseInvalide. statut(texte), si donné, reçoit une phrase courte à chaque étape (affichée dans l'app).
    Lève RuntimeError si tous échouent."""
    statut = statut or (lambda _texte: None)
    global _client
    if _client is None:  # créé à la demande : importer ce module ne demande pas de clé
        _client = genai.Client(api_key=GEMINI_API_KEY)
    dernier_erreur = None

    for nom_modele in modeles:
        for tentative in range(1, tentatives + 1):
            statut(f"Génération avec {nom_modele}" + (f" (essai {tentative}/{tentatives})" if tentative > 1 else "") + "…")
            try:
                response = _client.models.generate_content(model=nom_modele, contents=prompt, config=config)
                resultat = extraire(response)
                global dernier_modele
                dernier_modele = nom_modele
                return resultat
            except Exception as e:
                dernier_erreur = e
                if not _erreur_temporaire(e):
                    # Clé invalide, modèle inexistant, requête refusée : inutile d'attendre
                    print(f"Modèle {nom_modele} : erreur définitive ({e}), passage au modèle suivant.")
                    break
                if tentative == tentatives:
                    print(f"Modèle {nom_modele} : {tentatives} échecs ({e}), passage au modèle suivant.")
                    break
                attente = 20 * tentative   # 20s, 40s
                surcharge = isinstance(e, errors.APIError) and e.code in (429, 503)
                statut(f"{'Gemini surchargé' if surcharge else 'Erreur temporaire'} ({nom_modele}) : nouvel essai dans {attente} s…")
                print(f"Modèle {nom_modele} indisponible (tentative {tentative}/{NB_TENTATIVES} : {e}), nouvel essai dans {attente}s...")
                time.sleep(attente)

    raise RuntimeError(f"Échec avec tous les modèles Gemini : {dernier_erreur}")

def generer_json(prompt: str, schema: type, modeles: list = MODELES_GEMINI):
    """Réponse de Gemini, convertie dans le schéma pydantic donné, en essayant les modèles dans l'ordre.
    Lève RuntimeError si tous échouent."""
    def extraire(response):
        if response.parsed is None:
            raise ReponseInvalide(f"réponse non exploitable : {(response.text or '')[:200]!r}")
        return response.parsed
    config = {"response_mime_type": "application/json", "response_schema": schema, "temperature": 0.0}
    return _generer(prompt, config, extraire, modeles)

def generer_texte(prompt: str, modeles: list = MODELES_GEMINI, statut=None, tentatives: int = NB_TENTATIVES) -> str:
    """tentatives : essais par modèle (1 = passe tout de suite au suivant, quand un secours existe derrière)."""
    """Réponse libre (texte) de Gemini. Lève RuntimeError si tous les modèles échouent."""
    def extraire(response):
        texte = (response.text or "").strip()
        if not texte:
            raise ReponseInvalide("réponse vide")
        return texte
    return _generer(prompt, {"temperature": 0.3}, extraire, modeles, statut, tentatives)
