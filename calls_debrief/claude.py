"""Appels à Claude (API Anthropic) : Sonnet pour les résumés d'entretien, Haiku pour les tâches simples.

Chaque appel note son coût réel dans .etat/couts_claude.jsonl (suivi du crédit prépayé)."""
import json
import os
from datetime import datetime

import anthropic

from calls_debrief.config import ANTHROPIC_API_KEY
from calls_debrief.etat import DOSSIER_ETAT

FICHIER_COUTS = os.path.join(DOSSIER_ETAT, "couts_claude.jsonl")
# $ par million de tokens (entrée, sortie) ; la réflexion du modèle est facturée comme de la sortie
PRIX = {
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-sonnet-5": (2.00, 10.00),   # repli serveur de Sonnet 5.5 en cas de refus
    "claude-haiku-5-5": (0.10, 0.50),
}
NOMS = {"claude-sonnet-5-5": "Claude Sonnet 5.5", "claude-sonnet-5": "Claude Sonnet 5", "claude-haiku-5-5": "Claude Haiku 5.5"}
# Modèles qui acceptent le repli serveur en cas de refus (paramètre fallbacks)
AVEC_REPLI = {"claude-sonnet-5-5"}

_client = None

def disponible() -> bool:
    return bool(ANTHROPIC_API_KEY)

def nom(modele: str) -> str:
    return NOMS.get(modele, modele)

def _client_anthropic() -> anthropic.Anthropic:
    global _client
    if _client is None:
        _client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY, max_retries=3)
    return _client

def _cout(reponse) -> float | None:
    prix = PRIX.get(reponse.model)
    if not prix:
        return None
    u = reponse.usage
    entree = u.input_tokens + (u.cache_creation_input_tokens or 0) * 1.25 + (u.cache_read_input_tokens or 0) * 0.1
    return (entree * prix[0] + u.output_tokens * prix[1]) / 1_000_000

def _noter(reponse, tache: str) -> float | None:
    """Vérifie la réponse, note et renvoie son coût."""
    cout = _cout(reponse)
    u = reponse.usage
    print(f"Claude {reponse.model} : {u.input_tokens} tokens lus, {u.output_tokens} écrits"
          + (f", {cout:.4f} $" if cout is not None else ""))
    try:
        os.makedirs(DOSSIER_ETAT, exist_ok=True)
        with open(FICHIER_COUTS, "a", encoding="utf-8") as f:
            f.write(json.dumps({"date": datetime.now().isoformat(timespec="seconds"), "tache": tache,
                                "modele": reponse.model, "entree": u.input_tokens, "sortie": u.output_tokens,
                                "cout": cout}) + "\n")
    except OSError:
        pass
    if reponse.stop_reason == "refusal":
        raise RuntimeError("Claude a refusé la demande.")
    if reponse.stop_reason == "max_tokens":
        raise RuntimeError("réponse de Claude tronquée (limite de longueur atteinte).")
    return cout

def generer_texte(prompt: str, modele: str, effort: str, max_tokens: int, tache: str) -> tuple:
    """(texte, coût en $ ou None, modèle qui a répondu). Lève une exception en cas d'échec."""
    parametres = dict(model=modele, max_tokens=max_tokens, output_config={"effort": effort},
                      messages=[{"role": "user", "content": prompt}])
    client = _client_anthropic()
    if modele in AVEC_REPLI:
        reponse = client.beta.messages.create(**parametres, betas=["server-side-fallback-2026-07-01"], fallbacks="default")
    else:
        reponse = client.messages.create(**parametres)
    cout = _noter(reponse, tache)
    texte = "".join(b.text for b in reponse.content if b.type == "text").strip()
    if not texte:
        raise RuntimeError("réponse vide de Claude.")
    return texte, cout, reponse.model

def generer_json(prompt: str, schema: type, modele: str, tache: str, effort: str = "low", max_tokens: int = 4000):
    """Réponse convertie dans le schéma pydantic donné. Lève une exception en cas d'échec."""
    reponse = _client_anthropic().messages.parse(
        model=modele, max_tokens=max_tokens, output_config={"effort": effort}, output_format=schema,
        messages=[{"role": "user", "content": prompt}])
    _noter(reponse, tache)
    if reponse.parsed_output is None:
        raise RuntimeError("réponse JSON de Claude inexploitable.")
    return reponse.parsed_output
