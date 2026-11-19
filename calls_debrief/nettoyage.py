"""Nettoyage léger d'un transcript par Claude Haiku, lancé par l'app après la validation des noms :

    python -m calls_debrief.nettoyage --transcript <03_Transcripts/nom.txt>

Retire seulement les hésitations sonores (euh, hum…), corrige les mots mal reconnus et la ponctuation ; garde tout
le reste (tics de langage, gros mots, phrases inachevées). Le transcript brut est d'abord copié dans
03_Transcripts/.bruts/<nom>.txt (jamais écrasé : un nouveau nettoyage repart du brut). Les morceaux dont le
nettoyage paraît suspect (trop courts, locuteurs inventés) gardent leur version brute."""
import argparse
import os
import re
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor

from calls_debrief import claude
from calls_debrief.config import MODELE_LEGER, NOM_CANDIDAT

TAILLE_MORCEAU = 8000      # caractères par appel (coupé entre deux répliques)
RATIO_MIN, RATIO_MAX = 0.75, 1.15  # longueur nettoyée / brute acceptée pour un morceau
PREFIXE = re.compile(r"^([^:\n]{1,60}?) : ", re.M)

PROMPT = """Tu nettoies un extrait de la transcription automatique (Whisper) d'un appel{titre}. {nom} est la personne qui a enregistré l'appel.
{contexte}
Règles :
- Retire uniquement les hésitations sonores (euh, heu, hum, hmm) et les mots répétés par bégaiement (« le le », « je je »).
- Corrige les mots mal reconnus quand le contexte rend la correction évidente, surtout les noms propres, les noms d'entreprises et d'outils, et le jargon, y compris anglais (ex. « outband » → « outbound », « Gross Ops » → « Growth Ops »). Dans le doute, garde le mot tel quel.
- Corrige la ponctuation et les majuscules.
- Ne résume pas, ne reformule pas, ne réordonne pas, ne censure pas : garde tous les autres mots, y compris les tics de langage (« du coup », « genre », « en fait »), les gros mots, les phrases inachevées et les répétitions de mots ou de groupes de mots (« c'est pour ça que, c'est pour ça que »).
- Ne remplace jamais un mot familier ou argotique bien reconnu par un synonyme (« tu me rechoutes un message » reste tel quel, à l'orthographe près). Ne corrige pas la grammaire de l'oral.
- Garde exactement le préfixe de chaque réplique (« Nom : ») et une réplique par ligne, dans le même ordre.
- Réponds uniquement avec l'extrait nettoyé, sans commentaire ni balise.

Extrait :
{texte}"""

def statut(texte: str):
    print("STATUT: " + texte, flush=True)

def chemin_brut(transcript: str) -> str:
    dossier = os.path.join(os.path.dirname(transcript), ".bruts")
    return os.path.join(dossier, os.path.basename(transcript))

def decouper(texte: str) -> list:
    """Morceaux d'environ TAILLE_MORCEAU caractères, sans couper une réplique."""
    morceaux, courant = [], ""
    for ligne in texte.split("\n"):
        if courant and len(courant) + len(ligne) > TAILLE_MORCEAU:
            morceaux.append(courant)
            courant = ""
        courant += ligne + "\n"
    if courant.strip():
        morceaux.append(courant)
    return morceaux

def _suspect(brut: str, net: str) -> str:
    """Raison de rejeter un morceau nettoyé, ou chaîne vide s'il est acceptable."""
    def longueur(t: str) -> int:
        return len(re.sub(r"\s+", "", t))

    ratio = longueur(net) / max(1, longueur(brut))
    if not RATIO_MIN <= ratio <= RATIO_MAX:
        return f"longueur {ratio:.0%} de l'original"
    inventes = set(PREFIXE.findall(net)) - set(PREFIXE.findall(brut))
    if inventes:
        return f"locuteurs absents de l'original : {', '.join(sorted(inventes))}"
    return ""

def _nettoyer_morceau(args) -> tuple:
    """(texte, coût, rejeté) pour un morceau ; garde le brut en cas d'échec ou de doute."""
    numero, morceau, titre, profil = args
    contexte = (f"\nPour reconnaître son vocabulaire (domaine, outils, entreprises), voici son profil :\n{profil}\n"
                if profil else "")
    prompt = PROMPT.format(titre=f" (« {titre} »)" if titre else "", nom=NOM_CANDIDAT or "La personne",
                           contexte=contexte, texte=morceau)
    try:
        net, cout, _ = claude.generer_texte(prompt, MODELE_LEGER, "low", 8000, tache="nettoyage")
    except Exception as e:
        print(f"Morceau {numero} : échec ({e}), version brute gardée.")
        return morceau, 0.0, True
    raison = _suspect(morceau, net)
    if raison:
        print(f"Morceau {numero} : nettoyage suspect ({raison}), version brute gardée.")
        return morceau, cout or 0.0, True
    return net.strip() + "\n", cout or 0.0, False

def nettoyer(texte: str, titre: str = "") -> tuple:
    """(texte nettoyé, coût total, nombre de morceaux gardés bruts, nombre de morceaux)."""
    from calls_debrief.resume import lire_profil
    profil = lire_profil()
    morceaux = decouper(texte)
    statut(f"Nettoyage avec {claude.nom(MODELE_LEGER)} ({len(morceaux)} morceau{'x' if len(morceaux) > 1 else ''})…")
    with ThreadPoolExecutor(max_workers=4) as pool:
        resultats = list(pool.map(_nettoyer_morceau, [(i + 1, m, titre, profil) for i, m in enumerate(morceaux)]))
    net = "".join(r[0] for r in resultats).rstrip("\n")
    return net, sum(r[1] for r in resultats), sum(r[2] for r in resultats), len(morceaux)

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--transcript", required=True)
    args = parser.parse_args()
    if not claude.disponible():
        print("ANTHROPIC_API_KEY manquant dans .env : le nettoyage utilise Claude Haiku. Transcript inchangé.")
        sys.exit(2)  # code 2 : nettoyage indisponible, l'app n'affiche pas d'erreur

    brut = chemin_brut(args.transcript)
    source = brut if os.path.exists(brut) else args.transcript  # un nouveau nettoyage repart toujours du brut
    with open(source, encoding="utf-8") as f:
        texte = f.read()
    if not texte.strip():
        sys.exit("Le transcript est vide.")
    titre = os.path.splitext(os.path.basename(args.transcript))[0]

    net, cout, rejetes, total = nettoyer(texte, titre)
    if rejetes == total:
        sys.exit("Aucun morceau n'a pu être nettoyé : transcript inchangé (détails dans le journal).")

    if not os.path.exists(brut):
        os.makedirs(os.path.dirname(brut), exist_ok=True)
        shutil.copy2(args.transcript, brut)
    temporaire = os.path.join(os.path.dirname(brut), os.path.basename(args.transcript) + ".tmp")
    with open(temporaire, "w", encoding="utf-8") as f:
        f.write(net)
    os.replace(temporaire, args.transcript)
    print(f"Transcript nettoyé ({total - rejetes}/{total} morceaux, {cout:.4f} $). Brut gardé dans {brut}")

if __name__ == "__main__":
    main()
