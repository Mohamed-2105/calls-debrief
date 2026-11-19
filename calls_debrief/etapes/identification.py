"""Proposition à valider dans l'app : qui parle sous chaque étiquette SPEAKER_XX, nom et catégorie de l'appel.

Gemini préremplit les noms ; rien n'est appliqué au transcript avant ta validation dans l'app (outils/app/Fenetre.swift,
PanneauValidation). Sans Gemini (pas de clé, quota, réseau), le panneau s'affiche quand même, avec des champs vides."""
import re
from typing import Literal

from pydantic import BaseModel, Field

from calls_debrief.config import GEMINI_API_KEY, MODELE_LEGER, NOM_CANDIDAT

ETIQUETTE = re.compile(r"^(SPEAKER_\d+) : (.*)$")
LONGUEUR_EXTRAIT = 110

class Locuteur(BaseModel):
    etiquette: str = Field(description="Étiquette telle qu'elle apparaît dans la transcription, ex. SPEAKER_00.")
    # Rempli avant le nom : oblige le modèle à s'appuyer sur des répliques précises plutôt que sur l'ordre d'apparition
    indices: str = Field(description="Une ou deux répliques de cette étiquette qui montrent qui parle, citées brièvement.")
    nom: str = Field(description="Prénom (et nom s'il est dit) de la personne qui parle sous cette étiquette.")

class Identification(BaseModel):
    locuteurs: list[Locuteur]
    nom_propose: str = Field(description="Nom de l'appel, ex. 'Acme - Julie Martin (Head of GTM Eng.)'. Vide si inconnu.")
    categorie: Literal["entretien", "pro", "perso"] = Field(description="Type d'appel : entretien, pro ou perso.")

PROMPT = """Voici la transcription automatique d'un appel. {nom} est la personne qui l'a enregistré (le plus souvent en entretien ou en prise de contact pour un stage ou un poste).

TÂCHE 1 — LOCUTEURS
Les répliques sont préfixées par des étiquettes issues d'une détection automatique des voix : {etiquettes}.
Pour chaque étiquette, indique qui parle, en te fondant sur le contexte : présentations (« I'm… », « je suis… »), prénom utilisé pour s'adresser à l'autre, rôle dans l'échange.
- L'étiquette qui correspond à {nom} reçoit exactement le nom "{nom}". Indices typiques : c'est {nom} qui se présente (études, parcours, recherche de stage ou de poste), remercie l'autre de prendre le temps, et pose des questions sur le poste ou l'entreprise.
- ATTENTION : la personne qui dit « Hey Hugo » ou « Merci Léa » n'est PAS Hugo ni Léa, c'est son interlocuteur. Un prénom dans une réplique désigne en général l'AUTRE personne, sauf dans une présentation (« I'm… », « je m'appelle… »).
- La détection découpe souvent une même voix en deux étiquettes, même quand l'appel n'a que deux participants. Si les répliques d'une étiquette prolongent celles d'une autre (même rôle, même sujet, on ne s'adresse jamais à elle comme à une nouvelle personne), c'est la même personne : donne-leur le même nom. Ne crée un participant supplémentaire que si l'appel le montre clairement (présentation, prénom différent).
- Si le nom d'une personne n'est jamais dit, utilise "Interlocuteur" (puis "Interlocuteur 2"… s'il y en a plusieurs sans nom).
- N'invente jamais de nom. Les noms propres peuvent être mal transcrits : retiens l'orthographe la plus plausible.
{consigne_sans_etiquettes}
TÂCHE 2 — NOM DE L'APPEL
Propose un nom pour l'appel, centré sur l'interlocuteur principal (jamais {nom}), au format "Entreprise - Prénom Nom (Rôle)".
- Exemples : "Acme - Julie Martin (Head of GTM Eng.)", "Acme - Hugo (GTM Eng.)", "Globex - Sam (Head of Sales)".
- Rôle court et abrégé comme dans les exemples.
- Omets ce qui n'est pas dit dans l'appel : "Entreprise - Prénom", "Prénom Nom (Rôle)", etc. Plusieurs interlocuteurs : "Entreprise - Prénom1 & Prénom2".
- Chaîne vide si ni le nom de l'interlocuteur ni son entreprise ne ressortent de l'appel.

TÂCHE 3 — CATÉGORIE
Classe l'appel dans une catégorie :
- "entretien" : entretien d'embauche ou de stage, échange avec un recruteur, prise de contact ou discussion de réseau au sujet d'un poste.
- "pro" : tout autre échange professionnel ou d'études (réunion, client, partenaire, projet, cours).
- "perso" : appel personnel (famille, amis, démarches de la vie courante).

Transcription :
{texte}"""

def nettoyer_nom(nom: str) -> str:
    """Nom de fichier sûr (mêmes règles que le renommage de l'app) : ni / ni :, pas de point en tête."""
    nom = re.sub(r"\s+", " ", nom.replace("/", "-").replace(":", "-")).strip().lstrip(".").strip()
    return nom[:150].rstrip()

def _extraits(texte: str) -> dict:
    """Pour chaque étiquette, sa plus longue réplique (tronquée) : de quoi reconnaître la voix dans l'app."""
    extraits = {}
    for ligne in texte.splitlines():
        if (m := ETIQUETTE.match(ligne)) and len(m[2]) > len(extraits.get(m[1], "")):
            extraits[m[1]] = m[2]
    for etiquette, replique in extraits.items():
        if len(replique) > LONGUEUR_EXTRAIT:
            extraits[etiquette] = replique[:LONGUEUR_EXTRAIT].rsplit(" ", 1)[0] + "…"
    return extraits

def _identifier(texte: str, etiquettes: list) -> Identification | None:
    """Noms préremplis par Claude Haiku (si ANTHROPIC_API_KEY), sinon Gemini ; None si aucun n'est disponible."""
    consigne = "" if etiquettes else "(Cette transcription n'a pas d'étiquettes : renvoie une liste de locuteurs vide.)\n"
    prompt = PROMPT.format(nom=NOM_CANDIDAT or "La personne qui enregistre", texte=texte,
                           etiquettes=", ".join(etiquettes) or "aucune", consigne_sans_etiquettes=consigne)

    from calls_debrief import claude
    if claude.disponible():
        try:
            return claude.generer_json(prompt, Identification, MODELE_LEGER, tache="identification")
        except Exception as e:
            print(f"Préremplissage Claude impossible ({e}) : essai avec Gemini.")
    if not GEMINI_API_KEY:
        print("Ni Claude ni Gemini disponibles : proposition sans noms préremplis.")
        return None
    from calls_debrief.gemini import generer_json  # importe google-genai seulement si la clé est là
    try:
        return generer_json(prompt, Identification)
    except Exception as e:
        print(f"Préremplissage Gemini impossible ({e}) : proposition sans noms préremplis.")
        return None

def proposer(texte: str) -> dict | None:
    """{"nom": nom de l'appel, "categorie": entretien/pro/perso ou "", "locuteurs": [{"etiquette", "nom", "extrait"}]}, ou None s'il n'y a rien à valider."""
    extraits = _extraits(texte)
    etiquettes = sorted(extraits)
    identification = _identifier(texte, etiquettes)
    noms = {}
    nom_appel = ""
    categorie = ""
    if identification:
        noms = {loc.etiquette: loc.nom.strip() for loc in identification.locuteurs if loc.etiquette in extraits}
        nom_appel = nettoyer_nom(identification.nom_propose)
        categorie = identification.categorie
    if not etiquettes and not nom_appel and not categorie:
        return None
    return {
        "nom": nom_appel,
        "categorie": categorie,
        "locuteurs": [{"etiquette": e, "nom": noms.get(e, ""), "extrait": extraits[e]} for e in etiquettes],
    }
