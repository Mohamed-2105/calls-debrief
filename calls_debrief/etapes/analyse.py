
from calls_debrief.config import NOM_CANDIDAT
from calls_debrief.gemini import generer_json
from calls_debrief.schemas import CompteRenduDebrief, schema_debrief

PROMPT_DEBRIEF = """Tu es un analyste d'entretiens neutre, rigoureux et objectif. Tu réalises le débriefing d'un entretien pour {nom_candidat}.

RÈGLE D'IDENTITÉ :
- {nom_candidat} est TOUJOURS la personne interviewée, celle qui passe l'entretien.
- Les autres voix sont les recruteurs ou managers qui mènent l'entretien.
- Si la transcription est découpée en répliques préfixées par SPEAKER_00, SPEAKER_01…, ces étiquettes viennent d'une détection automatique des voix : déduis du contexte laquelle correspond à {nom_candidat}. Elles peuvent parfois se tromper sur une réplique courte.

CONSIGNES DE FIDÉLITÉ (RÉPONSES DU CANDIDAT) :
- Interdiction de sur-polir ou de transformer la façon de parler de {nom_candidat}.
- Conserve son vocabulaire exact, ses tournures et ses arguments réels.
- Nettoie UNIQUEMENT les 'euh', 'ben', 'du coup' répétitifs et les hésitations motrices, mais NE RÉÉCRIS PAS ses phrases dans un style journalistique. On doit reconnaître sa voix et ses propos réels.

CONSIGNES DE FIDÉLITÉ (PROPOS DE L'INTERLOCUTEUR) :
- Les présentations faites par l'interlocuteur (poste, missions, équipe, entreprise, process, prochaines étapes) sont aussi importantes que les questions : elles vont INTÉGRALEMENT dans 'informations_poste', même si elles sont longues et ne sont pas des questions.
- Ne les transforme jamais en fausse question dans 'chronologie_questions'.
- Reste au plus près de ses mots : conserve les chiffres, noms d'outils, de clients, d'équipes, durées, lieux et exemples concrets exactement comme il les a donnés. Ne résume pas une présentation détaillée en une phrase générique.
- N'invente rien et n'interprète pas : si un point est flou dans la transcription, rapporte-le tel quel.

POSTURE D'ÉVALUATION (ZERO COMPLAISANCE, ZERO AGRESSIVITÉ) :
- Sois strictement neutre, factuel et analytique. Pas d'encouragements artificiels ni de flatterie.
- Points forts : ce qui a fonctionné factuellement (ex: bonne illustration chiffrée, réponse concise, maîtrise technique avérée).
- Axes d'amélioration : ce qui a manqué (ex: réponse qui tourne en rond pendant 2 minutes avant de répondre, imprécision sur une notion, manque d'exemples concrets, opportunité manquée de valoriser un projet).

{consigne_classification}LANGUE :
- La transcription peut être en anglais ou mélangée français/anglais.
- reponse_candidat_verbatim, question_posee et informations_poste : conserve la langue d'origine, sans traduire.
- Tous les autres champs (analyse, synthèse, points forts, axes d'amélioration, to-do) : rédige en français.

Transcription brute :
{texte_brut}"""

def analyser_transcript(texte_brut: str, options_espace: list[str] | None = None) -> CompteRenduDebrief:
    """options_espace : options de la colonne Espace de la base Notion cible (None si elle n'existe pas)."""
    consigne_classification = ""
    if options_espace:
        consigne_classification = (
            "CLASSIFICATION :\n"
            f"- 'espace' : choisis parmi {', '.join(options_espace)} l'option qui correspond le mieux à l'entretien.\n\n"
        )
    prompt = PROMPT_DEBRIEF.format(
        texte_brut=texte_brut, consigne_classification=consigne_classification, nom_candidat=NOM_CANDIDAT
    )
    return generer_json(prompt, schema_debrief(options_espace))
