// Fenêtre principale : dépôt d'enregistrements (iPhone, Dictaphone…), avancement de la transcription
// et historique des transcripts (tri, filtre par catégorie, renommage sur place, corbeille, résumés IA).

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Formats acceptés par pipeline_calls.py (EXTENSIONS_AUDIO + EXTENSIONS_TEXTE dans config.py)
let extensionsAudio: Set<String> = ["m4a", "mp3", "wav"]
let extensionsAcceptees: Set<String> = extensionsAudio.union(["txt", "vtt", "srt"])

struct Appel: Identifiable, Hashable {
    enum Etat: Hashable { case pret, enCours, enAttente }
    let id: URL          // transcript s'il existe, sinon fichier à traiter
    let fichier: String  // nom de fichier sans extension, commun à l'audio, au transcript et au cache
    let nom: String      // nom affiché
    let date: Date       // date de l'appel (pas celle du fichier)
    let etat: Etat
    let categorie: Categorie?
}

/// Écrite par le pipeline Python dans .etat/propositions.json, à la fin de la transcription d'un appel
struct Proposition: Equatable {
    struct Locuteur: Equatable {
        let etiquette: String  // SPEAKER_00…
        let nom: String        // prérempli par Gemini, vide s'il n'a pas pu
        let extrait: String    // réplique type, pour reconnaître la voix
    }
    let nom: String            // nom de l'appel proposé
    let categorie: Categorie?  // type d'appel proposé
    let locuteurs: [Locuteur]
}

/// Avancement écrit par le pipeline Python dans .etat/progression.json
struct Progression: Equatable {
    let fichier: String
    let etape: String
    let fraction: Double?
    let debut: Date
}

enum Tri: String, CaseIterable, Identifiable {
    case recents, anciens, az, za
    var id: String { rawValue }
    var titre: String {
        switch self {
        case .recents: return "Plus récents d'abord"
        case .anciens: return "Plus anciens d'abord"
        case .az: return "Nom (A → Z)"
        case .za: return "Nom (Z → A)"
        }
    }

    func trier(_ appels: [Appel]) -> [Appel] {
        switch self {
        case .recents: return appels.sorted { $0.date > $1.date }
        case .anciens: return appels.sorted { $0.date < $1.date }
        case .az: return appels.sorted { $0.nom.localizedStandardCompare($1.nom) == .orderedAscending }
        case .za: return appels.sorted { $0.nom.localizedStandardCompare($1.nom) == .orderedDescending }
        }
    }
}

enum Filtre: String, CaseIterable, Identifiable {
    case tous, entretien, pro, perso, nonClasses
    var id: String { rawValue }
    var titre: String {
        switch self {
        case .tous: return "Toutes catégories"
        case .nonClasses: return "Non classés"
        default: return Categorie(rawValue: rawValue)?.titre ?? rawValue
        }
    }

    func garde(_ appel: Appel) -> Bool {
        switch self {
        case .tous: return true
        case .nonClasses: return appel.categorie == nil
        default: return appel.categorie?.rawValue == rawValue
        }
    }
}

enum ErreurFichiers: LocalizedError {
    case nomVide, dejaPris(String), transcriptionEnCours(String), resumeEnCours(String), nettoyageEnCours(String)

    var errorDescription: String? {
        switch self {
        case .nomVide: return "Le nom ne peut pas être vide."
        case .dejaPris(let nom): return "Un fichier « \(nom) » existe déjà."
        case .transcriptionEnCours(let action): return "Attends la fin de la transcription en cours pour \(action)."
        case .resumeEnCours(let action): return "Attends la fin du résumé de cet appel pour \(action)."
        case .nettoyageEnCours(let action): return "Attends la fin du nettoyage du transcript pour \(action)."
        }
    }
}

final class Historique: ObservableObject {
    @Published var appels: [Appel] = []
    @Published var transcriptionEnCours = false
    @Published var progression: Progression?
    /// Propositions en attente de validation : {nom de fichier actuel: proposition}
    @Published var propositions: [String: Proposition] = [:]
    /// Appels (nom de fichier) qui ont un résumé dans 04_Resumes
    @Published var resumes: Set<String> = []
    /// Résumés en cours de génération, et dernière erreur par appel
    @Published var resumesEnCours: Set<String> = []
    @Published var erreursResume: [String: String] = [:]
    /// Transcripts nettoyés par Claude Haiku (brut gardé dans 03_Transcripts/.bruts), nettoyages en cours et erreurs
    @Published var nettoyes: Set<String> = []
    @Published var nettoyagesEnCours: Set<String> = []
    @Published var erreursNettoyage: [String: String] = [:]
    /// Journal et heure de début de la tâche en cours sur chaque appel (résumé ou nettoyage), pour afficher l'étape
    private var journauxTaches: [String: (journal: URL, debut: Date)] = [:]
    private var bruts: URL { reglages.transcripts.appendingPathComponent(".bruts") }
    /// Appelé à la fin d'un résumé (nom de fichier, réussi) : notification
    var finResume: ((String, Bool) -> Void)?
    let reglages: Reglages

    /// Dates et catégories des appels, mémorisées dans 03_Transcripts/.calls-debrief.json : la date de modification
    /// des fichiers change dès qu'ils sont copiés ou retranscrits, elle ne dit pas quand l'appel a eu lieu.
    private var dates: [String: Date] = [:]
    private var categories: [String: Categorie] = [:]
    private var datesEnCalcul: Set<String> = []
    private var fichierMeta: URL { reglages.transcripts.appendingPathComponent(".calls-debrief.json") }

    init(reglages: Reglages) {
        self.reglages = reglages
        chargerMeta()
        recharger()
    }

    // MARK: Liste

    /// Fichiers d'un dossier, sauf ceux dont le nom commence par « . » (temporaires). Pas `.skipsHiddenFiles` :
    /// il écarte aussi les fichiers marqués cachés par macOS (drapeau « hidden »), qui sont de vrais appels.
    private func fichiers(_ dossier: URL) -> [URL] {
        let tous = (try? FileManager.default.contentsOfDirectory(at: dossier, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return tous.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    func recharger() {
        let progression = transcriptionEnCours ? lireProgression() : nil
        if progression != self.progression { self.progression = progression }

        let textes = fichiers(reglages.transcripts).filter { $0.pathExtension == "txt" }
        let nomsTranscrits = Set(textes.map { $0.deletingPathExtension().lastPathComponent })
        var liste = textes.map { creerAppel(id: $0, etat: .pret) }
        // Fichiers déposés mais pas encore transcrits
        for f in fichiers(reglages.aTraiter) where extensionsAcceptees.contains(f.pathExtension.lowercased()) {
            if !nomsTranscrits.contains(f.deletingPathExtension().lastPathComponent) {
                let enCours = transcriptionEnCours && progression?.fichier == f.lastPathComponent
                liste.append(creerAppel(id: f, etat: enCours ? .enCours : .enAttente))
            }
        }
        if liste != appels { appels = liste }
        let propositions = lirePropositions()
        if propositions != self.propositions { self.propositions = propositions }
        let resumes = Set(fichiers(reglages.resumes).filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent })
        if resumes != self.resumes { self.resumes = resumes }
        let nettoyes = Set(fichiers(bruts).filter { $0.pathExtension == "txt" }.map { $0.deletingPathExtension().lastPathComponent })
        if nettoyes != self.nettoyes { self.nettoyes = nettoyes }
    }

    private func creerAppel(id: URL, etat: Appel.Etat) -> Appel {
        let fichier = id.deletingPathExtension().lastPathComponent
        let date = dates[fichier] ?? Self.dateDepuisNom(fichier) ?? Self.dateDeCreation(id) ?? .distantPast
        if dates[fichier] == nil { resoudreDate(fichier) }
        return Appel(id: id, fichier: fichier, nom: Self.joli(fichier), date: date, etat: etat, categorie: categories[fichier])
    }

    func lireProgression() -> Progression? {
        guard let data = try? Data(contentsOf: reglages.progression),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Progression(
            fichier: json["fichier"] as? String ?? "",
            etape: json["etape"] as? String ?? "Transcription",
            fraction: json["fraction"] as? Double,
            debut: Date(timeIntervalSince1970: json["debut"] as? Double ?? Date().timeIntervalSince1970))
    }

    /// "appel_2026-11-19_14h05" -> "Appel du 19/11/2026 à 14h05" ; les autres noms restent tels quels.
    static func joli(_ nom: String) -> String {
        let parties = nom.split(separator: "_")
        guard parties.count >= 3, parties[0] == "appel" else { return nom }
        let jour = parties[1].split(separator: "-")
        guard jour.count == 3 else { return nom }
        return "Appel du \(jour[2])/\(jour[1])/\(jour[0]) à \(parties[2])"
    }

    // MARK: Dates des appels

    /// Date inscrite dans le nom des enregistrements de l'app : "appel_2026-11-19_14h05"
    static func dateDepuisNom(_ nom: String) -> Date? {
        let parties = nom.split(separator: "_")
        guard parties.count >= 3, parties[0] == "appel" else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd'_'HH'h'mm"
        return format.date(from: "\(parties[1])_\(parties[2])")
    }

    static func dateDeCreation(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private func chargerMeta() {
        guard let data = try? Data(contentsOf: fichierMeta),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        dates = (json["dates"] as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        categories = (json["categories"] as? [String: String] ?? [:]).compactMapValues(Categorie.init(rawValue:))
    }

    private func enregistrerMeta() {
        let json: [String: Any] = ["dates": dates.mapValues { $0.timeIntervalSince1970 },
                                   "categories": categories.mapValues(\.rawValue)]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fichierMeta, options: .atomic)
        }
    }

    // MARK: Catégories

    func definirCategorie(_ appel: Appel, _ categorie: Categorie?) {
        guard categories[appel.fichier] != categorie else { return }
        categories[appel.fichier] = categorie
        enregistrerMeta()
        recharger()
    }

    /// Cherche une fois pour toutes la vraie date d'un appel, puis la mémorise :
    /// nom "appel_…", sinon date d'enregistrement inscrite dans l'audio (Dictaphone), sinon le plus ancien fichier.
    private func resoudreDate(_ fichier: String) {
        guard !datesEnCalcul.contains(fichier) else { return }
        datesEnCalcul.insert(fichier)
        let sources = [reglages.aTraiter, reglages.archives, reglages.transcripts]
            .flatMap(fichiers)
            .filter { $0.deletingPathExtension().lastPathComponent == fichier }

        Task {
            var date = Self.dateDepuisNom(fichier)
            if date == nil {
                for audio in sources where extensionsAudio.contains(audio.pathExtension.lowercased()) {
                    if let item = try? await AVURLAsset(url: audio).load(.creationDate),
                       let valeur = try? await item.load(.dateValue) {
                        date = valeur
                        break
                    }
                }
            }
            if date == nil { date = sources.compactMap(Self.dateDeCreation).min() }
            let trouvee = date
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.datesEnCalcul.remove(fichier)
                guard let date = trouvee, self.dates[fichier] == nil else { return }
                self.dates[fichier] = date
                self.enregistrerMeta()
                self.recharger()
            }
        }
    }

    // MARK: Fichiers d'un appel

    /// Tous les fichiers d'un appel : transcript, résumé, audio (à traiter et archivé) et cache de transcription.
    /// `suite` est ce qui suit le nom : ".txt", ou ".m4a_1234.txt" / ".m4a_1234.segments.json" pour le cache.
    private func fichiersLies(_ nom: String) -> [(fichier: URL, dossier: URL, suite: String)] {
        var liste: [(URL, URL, String)] = []
        for dossier in [reglages.transcripts, bruts, reglages.resumes, reglages.aTraiter, reglages.archives] {
            for f in fichiers(dossier) where f.deletingPathExtension().lastPathComponent == nom {
                liste.append((f, dossier, "." + f.pathExtension))
            }
        }
        for f in fichiers(reglages.cache) {
            let nomCache = f.lastPathComponent
            guard nomCache.hasPrefix(nom + ".") else { continue }
            let suite = nomCache.dropFirst(nom.count + 1)
            guard let ext = suite.split(separator: "_").first, extensionsAudio.contains(ext.lowercased()) else { continue }
            liste.append((f, reglages.cache, "." + suite))
        }
        return liste
    }

    /// Déplace tout ou rien : en cas d'échec, les fichiers déjà déplacés reviennent à leur place.
    private func deplacer(_ deplacements: [(URL, URL)]) throws {
        let fm = FileManager.default
        var faits: [(URL, URL)] = []
        do {
            for (source, destination) in deplacements {
                try fm.moveItem(at: source, to: destination)
                faits.append((source, destination))
            }
        } catch {
            for (source, destination) in faits.reversed() { try? fm.moveItem(at: destination, to: source) }
            throw error
        }
    }

    // MARK: Renommage

    /// Renomme ensemble le transcript, l'audio et le cache, pour que le pipeline ne retranscrive pas le fichier.
    /// Renvoie le nouvel identifiant de l'appel.
    func renommer(_ appel: Appel, en saisie: String) throws -> URL {
        guard !transcriptionEnCours else { throw ErreurFichiers.transcriptionEnCours("renommer") }
        guard !resumesEnCours.contains(appel.fichier) else { throw ErreurFichiers.resumeEnCours("le renommer") }
        guard !nettoyagesEnCours.contains(appel.fichier) else { throw ErreurFichiers.nettoyageEnCours("le renommer") }
        var nouveau = saisie.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while nouveau.hasPrefix(".") { nouveau.removeFirst() }
        guard !nouveau.isEmpty else { throw ErreurFichiers.nomVide }
        let ancien = appel.fichier
        guard nouveau != ancien else {
            retirerProposition(ancien)
            return appel.id
        }

        let deplacements = fichiersLies(ancien).map { ($0.fichier, $0.dossier.appendingPathComponent(nouveau + $0.suite)) }
        let fm = FileManager.default
        for (source, destination) in deplacements where fm.fileExists(atPath: destination.path)
            && source.path.lowercased() != destination.path.lowercased() {  // simple changement de casse : autorisé
            throw ErreurFichiers.dejaPris(destination.lastPathComponent)
        }
        try deplacer(deplacements)

        dates[nouveau] = dates[ancien] ?? appel.date  // garde la date même si le nom "appel_…" la portait
        dates[ancien] = nil
        categories[nouveau] = categories.removeValue(forKey: ancien)
        erreursResume[ancien] = nil
        erreursNettoyage[ancien] = nil
        enregistrerMeta()
        retirerProposition(ancien)
        recharger()
        let ext = appel.id.pathExtension
        return appel.id.deletingLastPathComponent().appendingPathComponent(nouveau).appendingPathExtension(ext)
    }

    // MARK: Validation des locuteurs et du nom

    /// Écrit par le pipeline Python (.etat/propositions.json) ; l'app n'y touche que hors transcription.
    private func lireJSONPropositions() -> [String: Any] {
        guard let data = try? Data(contentsOf: reglages.propositions),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func lirePropositions() -> [String: Proposition] {
        lireJSONPropositions().compactMapValues { valeur in
            guard let objet = valeur as? [String: Any] else { return nil }
            let locuteurs = (objet["locuteurs"] as? [[String: Any]] ?? []).compactMap { l -> Proposition.Locuteur? in
                guard let etiquette = l["etiquette"] as? String else { return nil }
                return .init(etiquette: etiquette, nom: l["nom"] as? String ?? "", extrait: l["extrait"] as? String ?? "")
            }
            return Proposition(nom: objet["nom"] as? String ?? "",
                               categorie: (objet["categorie"] as? String).flatMap(Categorie.init(rawValue:)),
                               locuteurs: locuteurs)
        }
    }

    private func retirerProposition(_ fichier: String) {
        var json = lireJSONPropositions()
        guard json.removeValue(forKey: fichier) != nil else { return }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reglages.propositions, options: .atomic)
        }
        propositions = lirePropositions()
    }

    /// Ignore les noms proposés ; la catégorie proposée est gardée si l'appel n'en a pas encore.
    func ignorerProposition(_ appel: Appel) throws {
        guard !transcriptionEnCours else { throw ErreurFichiers.transcriptionEnCours("modifier l'appel") }
        if appel.categorie == nil, let categorie = propositions[appel.fichier]?.categorie {
            definirCategorie(appel, categorie)
        }
        retirerProposition(appel.fichier)
    }

    /// Enregistre la catégorie, renomme l'appel (si un nom est donné), puis remplace les étiquettes SPEAKER_XX
    /// par les noms dans le transcript. Renvoie le nouvel identifiant de l'appel.
    func valider(_ appel: Appel, noms: [String: String], nom: String, categorie: Categorie?) throws -> URL {
        guard !transcriptionEnCours else { throw ErreurFichiers.transcriptionEnCours("valider") }
        guard !nettoyagesEnCours.contains(appel.fichier) else { throw ErreurFichiers.nettoyageEnCours("valider") }
        let nouveau = nom.trimmingCharacters(in: .whitespacesAndNewlines)
        if categorie != nil { definirCategorie(appel, categorie) }  // avant renommer(), qui la déplace
        let id = nouveau.isEmpty ? appel.id : try renommer(appel, en: nouveau)
        let texte = try String(contentsOf: id, encoding: .utf8)
        try Self.appliquerNoms(texte, noms).write(to: id, atomically: true, encoding: .utf8)
        retirerProposition(appel.fichier)  // déjà fait par renommer() si le nom a changé
        recharger()
        return id
    }

    /// "SPEAKER_00 : …" -> "Hugo : …" ; les répliques consécutives d'une même personne sont regroupées
    /// (utile quand deux étiquettes désignaient la même voix). Une étiquette sans nom reste telle quelle.
    static func appliquerNoms(_ texte: String, _ noms: [String: String]) -> String {
        var lignes: [String] = []
        var precedent: String?
        for ligne in texte.components(separatedBy: "\n") {
            guard let prefixe = ligne.range(of: #"^SPEAKER_\d+ : "#, options: .regularExpression) else {
                lignes.append(ligne)
                precedent = nil
                continue
            }
            let etiquette = String(ligne[prefixe].dropLast(3))
            let replique = String(ligne[prefixe.upperBound...])
            let saisi = (noms[etiquette] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let nom = saisi.isEmpty ? etiquette : saisi
            if nom == precedent, !lignes.isEmpty {
                lignes[lignes.count - 1] += " " + replique
            } else {
                lignes.append("\(nom) : \(replique)")
                precedent = nom
            }
        }
        return lignes.joined(separator: "\n")
    }

    // MARK: Corbeille

    /// Déplace tous les fichiers de l'appel dans Corbeille/<nom> — <date>/, rangés par dossier d'origine
    /// (03_Transcripts, 01_A_Traiter, 02_Archives, cache) : pour restaurer, il suffit de les remettre en place.
    func mettreALaCorbeille(_ appel: Appel) throws {
        guard !transcriptionEnCours else { throw ErreurFichiers.transcriptionEnCours("supprimer") }
        guard !resumesEnCours.contains(appel.fichier) else { throw ErreurFichiers.resumeEnCours("le supprimer") }
        guard !nettoyagesEnCours.contains(appel.fichier) else { throw ErreurFichiers.nettoyageEnCours("le supprimer") }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH'h'mm'm'ss"
        let fm = FileManager.default
        var dossier = reglages.corbeille.appendingPathComponent("\(appel.fichier) — supprimé le \(format.string(from: Date()))")
        var n = 2
        while fm.fileExists(atPath: dossier.path) {
            dossier = reglages.corbeille.appendingPathComponent("\(appel.fichier) — supprimé le \(format.string(from: Date())) (\(n))")
            n += 1
        }

        var deplacements: [(URL, URL)] = []
        for (fichier, origine, _) in fichiersLies(appel.fichier) {
            let nomDossier = origine == reglages.cache ? "cache" : origine == bruts ? "03_Transcripts (bruts)" : origine.lastPathComponent
            let sousDossier = dossier.appendingPathComponent(nomDossier)
            try fm.createDirectory(at: sousDossier, withIntermediateDirectories: true)
            deplacements.append((fichier, sousDossier.appendingPathComponent(fichier.lastPathComponent)))
        }
        do {
            try deplacer(deplacements)
        } catch {
            try? fm.removeItem(at: dossier)
            throw error
        }

        dates[appel.fichier] = nil
        categories[appel.fichier] = nil
        erreursResume[appel.fichier] = nil
        enregistrerMeta()
        retirerProposition(appel.fichier)
        recharger()
    }

    /// Efface pour de bon ce qui est dans la corbeille depuis plus de `dureeCorbeille` jours.
    func viderCorbeille() {
        let limite = Date().addingTimeInterval(-Double(reglages.dureeCorbeille) * 86_400)
        for element in fichiers(reglages.corbeille) {
            if let suppression = Self.dateDeCreation(element), suppression < limite {
                try? FileManager.default.removeItem(at: element)
            }
        }
    }

    // MARK: Résumés IA

    func urlResume(_ appel: Appel) -> URL {
        reglages.resumes.appendingPathComponent(appel.fichier + ".md")
    }

    /// Lance `python -m <module> …` dans le projet, journal dans .etat/journaux ; `fin(code, journal)` sur le fil principal.
    private func lancerPython(_ arguments: [String], journal suffixe: String, entree: String? = nil,
                              fin: @escaping (Int32, URL) -> Void) throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: reglages.journaux, withIntermediateDirectories: true)
        let horodatage = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let journal = reglages.journaux.appendingPathComponent("\(horodatage)-\(suffixe).log")
        fm.createFile(atPath: journal.path, contents: nil)

        let process = Process()
        process.executableURL = reglages.python
        process.arguments = ["-m"] + arguments
        process.currentDirectoryURL = reglages.projet
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        if let sortie = try? FileHandle(forWritingTo: journal) {
            process.standardOutput = sortie
            process.standardError = sortie
        }
        let tube = Pipe()
        process.standardInput = entree == nil ? FileHandle.nullDevice : tube
        process.terminationHandler = { fini in
            DispatchQueue.main.async { fin(fini.terminationStatus, journal) }
        }
        try process.run()
        if let entree {
            tube.fileHandleForWriting.write(Data(entree.utf8))
            try? tube.fileHandleForWriting.close()
        }
        return journal
    }

    /// Lance calls_debrief.resume en arrière-plan ; `prompt` (prompt modifié pour ce résumé) est passé sur stdin.
    /// Le résumé remplace le précédent. Indépendant de la transcription.
    func genererResume(_ appel: Appel, format: FormatResume, prompt: String?) {
        guard appel.etat == .pret, !resumesEnCours.contains(appel.fichier),
              !nettoyagesEnCours.contains(appel.fichier) else { return }
        let fichier = appel.fichier
        let arguments = ["calls_debrief.resume", "--transcript", appel.id.path, "--format", format.rawValue]
            + (prompt == nil ? [] : ["--prompt-stdin"])
        do {
            let journal = try lancerPython(arguments, journal: "resume", entree: prompt) { [weak self] code, journal in
                guard let self else { return }
                self.resumesEnCours.remove(fichier)
                self.journauxTaches[fichier] = nil
                self.erreursResume[fichier] = code == 0 ? nil : Self.derniereLigne(journal)
                self.recharger()
                self.finResume?(fichier, code == 0)
            }
            resumesEnCours.insert(fichier)
            journauxTaches[fichier] = (journal, Date())
            erreursResume[fichier] = nil
        } catch {
            erreursResume[fichier] = error.localizedDescription
        }
    }

    // MARK: Nettoyage du transcript (Claude Haiku)

    func urlBrut(_ appel: Appel) -> URL { bruts.appendingPathComponent(appel.fichier + ".txt") }

    /// Corrige les erreurs de reconnaissance du transcript (calls_debrief.nettoyage) ; le brut est gardé dans
    /// 03_Transcripts/.bruts. Lancé après la validation des noms, ou à la main. Sans clé Claude : rien ne se passe.
    func nettoyer(_ appel: Appel) {
        guard appel.etat == .pret, !nettoyagesEnCours.contains(appel.fichier),
              !resumesEnCours.contains(appel.fichier) else { return }
        let fichier = appel.fichier
        do {
            let journal = try lancerPython(["calls_debrief.nettoyage", "--transcript", appel.id.path],
                                           journal: "nettoyage") { [weak self] code, journal in
                guard let self else { return }
                self.nettoyagesEnCours.remove(fichier)
                self.journauxTaches[fichier] = nil
                // Code 2 : pas de clé Claude, nettoyage simplement ignoré
                self.erreursNettoyage[fichier] = (code == 0 || code == 2) ? nil : Self.derniereLigne(journal)
                self.recharger()
            }
            nettoyagesEnCours.insert(fichier)
            journauxTaches[fichier] = (journal, Date())
            erreursNettoyage[fichier] = nil
        } catch {
            erreursNettoyage[fichier] = error.localizedDescription
        }
    }

    private static func derniereLigne(_ journal: URL) -> String {
        let texte = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
        return texte.split(separator: "\n").last { !$0.hasPrefix("STATUT: ") }.map(String.init) ?? "Erreur inconnue."
    }

    /// Dernière étape écrite par la tâche en cours sur cet appel (lignes "STATUT: …" du journal) et son début.
    func etapeTache(_ fichier: String) -> (texte: String, debut: Date)? {
        guard let (journal, debut) = journauxTaches[fichier] else { return nil }
        let lignes = ((try? String(contentsOf: journal, encoding: .utf8)) ?? "").split(separator: "\n")
        let etape = lignes.last { $0.hasPrefix("STATUT: ") }.map { String($0.dropFirst(8)) }
        return (etape ?? "Préparation…", debut)
    }

    // MARK: Import

    /// Copie les fichiers dans 01_A_Traiter (sans écraser) ; renvoie le nombre de fichiers acceptés.
    func importer(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: reglages.aTraiter, withIntermediateDirectories: true)
        var acceptes = 0
        for url in urls where extensionsAcceptees.contains(url.pathExtension.lowercased()) {
            let base = url.deletingPathExtension().lastPathComponent
            var destination = reglages.aTraiter.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: destination.path) {
                destination = reglages.aTraiter.appendingPathComponent("\(base) (\(n)).\(url.pathExtension)")
                n += 1
            }
            if (try? fm.copyItem(at: url, to: destination)) != nil { acceptes += 1 }
        }
        recharger()
        return acceptes
    }
}

// MARK: - Vues

struct ZoneDeDepot: View {
    @ObservedObject var historique: Historique
    let surImport: () -> Void
    @State private var survol = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down").font(.title2)
            Text("Dépose ici un enregistrement de ton iPhone")
                .font(.headline)
            Text(message ?? "Depuis Dictaphone, AirDrop ou le Finder (m4a, mp3, wav) — ou clique pour choisir")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .background(RoundedRectangle(cornerRadius: 10).fill(survol ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(survol ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .contentShape(Rectangle())
        .onTapGesture(perform: choisir)
        .dropDestination(for: URL.self) { urls, _ in
            importer(urls)
        } isTargeted: { survol = $0 }
        .padding([.horizontal, .top])
    }

    private func choisir() {
        let panneau = NSOpenPanel()
        panneau.allowsMultipleSelection = true
        panneau.allowedContentTypes = extensionsAcceptees.compactMap { UTType(filenameExtension: $0) }
        if panneau.runModal() == .OK { _ = importer(panneau.urls) }
    }

    @discardableResult
    private func importer(_ urls: [URL]) -> Bool {
        let n = historique.importer(urls)
        message = n == 0 ? "Format non reconnu : m4a, mp3, wav, txt, vtt ou srt."
            : "\(n) fichier\(n > 1 ? "s" : "") ajouté\(n > 1 ? "s" : "") — transcription lancée."
        if n > 0 { surImport() }
        return n > 0
    }
}

/// Étape, pourcentage et temps écoulé de la transcription en cours.
struct DetailProgression: View {
    let progression: Progression?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { contexte in
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = progression?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(legende(maintenant: contexte.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func legende(maintenant: Date) -> String {
        guard let progression else { return "Démarrage…" }
        var morceaux = [progression.etape]
        if let fraction = progression.fraction { morceaux.append("\(Int(fraction * 100)) %") }
        let ecoule = Int(maintenant.timeIntervalSince(progression.debut))
        morceaux.append(ecoule < 60 ? "\(ecoule) s" : "\(ecoule / 60) min \(String(format: "%02d", ecoule % 60)) s")
        return morceaux.joined(separator: " · ")
    }
}

struct BandeauTranscription: View {
    @ObservedObject var historique: Historique
    let ouvrirJournal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(titre).font(.headline).lineLimit(1)
                DetailProgression(progression: historique.progression)
            }
            Button("Voir le journal", action: ouvrirJournal)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        .padding([.horizontal, .top])
    }

    private var titre: String {
        guard let fichier = historique.progression?.fichier, !fichier.isEmpty else { return "Transcription en cours" }
        return "Transcription en cours : " + Historique.joli((fichier as NSString).deletingPathExtension)
    }
}

/// Nom d'un appel, modifiable sur place : double-clic, ou crayon qui apparaît au survol.
/// Entrée ou clic ailleurs valide, Échap annule.
struct NomModifiable: View {
    let nom: String
    let police: Font
    let peutRenommer: Bool
    @Binding var edition: Bool
    let valider: (String) -> Void
    @State private var saisie = ""
    @State private var survol = false
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 6) {
            if edition {
                TextField("Nom", text: $saisie)
                    .textFieldStyle(.plain).font(police)
                    .focused($focus)
                    .onSubmit(terminer)
                    .onExitCommand { edition = false }
                    .onChange(of: focus) { _, actif in if !actif { terminer() } }
                    .onAppear {
                        saisie = nom.replacingOccurrences(of: "/", with: "-")
                        DispatchQueue.main.async { focus = true }
                    }
            } else {
                Text(nom).font(police).lineLimit(1)
                    .onTapGesture(count: 2) { if peutRenommer { edition = true } }
                if peutRenommer {
                    Button { edition = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Renommer (ou double-clic sur le nom)")
                        .opacity(survol ? 1 : 0)
                }
            }
        }
        .onHover { survol = $0 }
    }

    private func terminer() {
        guard edition else { return }  // Entrée puis perte du focus : un seul renommage
        edition = false
        valider(saisie)
    }
}

/// Sous l'en-tête d'un appel fraîchement transcrit : qui parle sous chaque étiquette, nom et catégorie de l'appel.
/// Prérempli par Gemini ; rien n'est appliqué tant que tu n'as pas cliqué sur Valider.
struct PanneauValidation: View {
    let proposition: Proposition
    let categorieActuelle: Categorie?
    let candidat: String
    let actif: Bool
    let valider: ([String: String], String, Categorie?) -> Void
    let ignorer: () -> Void
    @State private var noms: [String: String] = [:]
    @State private var nom = ""
    @State private var categorie: Categorie?

    /// Ton prénom, puis les noms déjà proposés ou saisis
    private var suggestions: [String] {
        var liste: [String] = []
        for n in [candidat] + proposition.locuteurs.map(\.nom) + proposition.locuteurs.compactMap({ noms[$0.etiquette] }) {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !liste.contains(t) { liste.append(t) }
        }
        return liste
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !proposition.locuteurs.isEmpty {
                Text("Qui parle ?").font(.headline)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(proposition.locuteurs, id: \.etiquette) { l in
                        GridRow {
                            Text(l.etiquette).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("« \(l.extrait) »").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 2) {
                                TextField("Nom", text: champ(l.etiquette)).frame(width: 170)
                                Menu {
                                    ForEach(suggestions, id: \.self) { s in Button(s) { noms[l.etiquette] = s } }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .disabled(suggestions.isEmpty)
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Nom de l'appel").font(.headline)
                TextField("Entreprise - Prénom Nom (Rôle)", text: $nom)
                Picker("Catégorie", selection: $categorie) {
                    Text("Non classé").tag(Categorie?.none)
                    ForEach(Categorie.allCases) { c in Label(c.titre, systemImage: c.icone).tag(Categorie?.some(c)) }
                }
                .fixedSize()
            }
            HStack {
                Text("Même nom pour deux étiquettes : leurs répliques sont regroupées.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ignorer", action: ignorer)
                Button("Valider") { valider(noms, nom, categorie) }.buttonStyle(.borderedProminent)
            }
        }
        .disabled(!actif)
        .help(actif ? "" : "Disponible à la fin de la transcription en cours")
        .padding()
        .background(.tint.opacity(0.06))
        .onAppear(perform: remplir)
        .onChange(of: proposition) { _, _ in remplir() }
    }

    private func remplir() {
        noms = Dictionary(proposition.locuteurs.map { ($0.etiquette, $0.nom) }, uniquingKeysWith: { a, _ in a })
        nom = proposition.nom
        categorie = categorieActuelle ?? proposition.categorie
    }

    private func champ(_ etiquette: String) -> Binding<String> {
        Binding(get: { noms[etiquette] ?? "" }, set: { noms[etiquette] = $0 })
    }
}

/// Menu de la catégorie d'un appel (en-tête du transcript et menu contextuel de la liste).
struct ChoixCategorie: View {
    let categorie: Categorie?
    let choisir: (Categorie?) -> Void

    var body: some View {
        ForEach(Categorie.allCases) { c in
            Button { choisir(c) } label: {
                Label(c.titre, systemImage: categorie == c ? "checkmark" : c.icone)
            }
        }
        Divider()
        Button { choisir(nil) } label: {
            Label("Non classé", systemImage: categorie == nil ? "checkmark" : "tag")
        }
    }
}

/// Long texte sélectionnable dans une NSTextView : un Text SwiftUI de plusieurs dizaines de milliers de caractères
/// est recalculé en entier à chaque redimensionnement de la fenêtre (très lent en plein écran).
struct TexteDefilant: NSViewRepresentable {
    let texte: NSAttributedString

    init(_ texte: NSAttributedString) { self.texte = texte }

    func makeNSView(context: Context) -> NSScrollView {
        let defilement = NSScrollView()
        defilement.hasVerticalScroller = true
        defilement.drawsBackground = false
        let vue = ColonneDeLecture(frame: .zero)
        vue.isEditable = false
        vue.isSelectable = true
        vue.drawsBackground = false
        vue.isVerticallyResizable = true
        vue.isHorizontallyResizable = false
        vue.autoresizingMask = [.width]
        vue.textContainer?.widthTracksTextView = true
        vue.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        defilement.documentView = vue
        return defilement
    }

    func updateNSView(_ defilement: NSScrollView, context: Context) {
        guard let vue = defilement.documentView as? NSTextView,
              vue.textStorage?.isEqual(to: texte) == false else { return }
        vue.textStorage?.setAttributedString(texte)
        vue.scrollToBeginningOfDocument(nil)
    }
}

/// Texte centré dans une colonne de lecture d'au plus `largeurMax` points, quelle que soit la largeur de la fenêtre.
final class ColonneDeLecture: NSTextView {
    static let largeurMax: CGFloat = 760

    override func setFrameSize(_ taille: NSSize) {
        super.setFrameSize(taille)
        let marge = max(20, (taille.width - Self.largeurMax) / 2)
        if textContainerInset.width != marge { textContainerInset = NSSize(width: marge, height: 18) }
    }
}

/// Transcript "Nom : réplique" -> affichage lisible : nom en gras et en couleur (une par personne), espace entre
/// les répliques, longues tirades coupées en paragraphes. Le fichier, lui, garde son format.
enum MiseEnFormeTranscript {
    /// Bleu marine (plus clair en mode sombre pour rester lisible), noir, puis gris s'il y a plus de deux personnes
    private static let bleuMarine = NSColor(name: nil) { apparence in
        apparence.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.67, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.18, blue: 0.42, alpha: 1)
    }
    private static let couleurs: [NSColor] = [bleuMarine, .labelColor, .secondaryLabelColor]
    private static let prefixe = try! NSRegularExpression(pattern: #"^([^:\n]{1,60}?) : "#)
    private static let finDePhrase = try! NSRegularExpression(pattern: #"(?<=[.!?…])\s+(?=[«"A-ZÀ-ÝÉÈ0-9])"#)

    static func enAttribue(_ texte: String) -> NSAttributedString {
        let taille = NSFont.systemFontSize + 1
        let corps: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: taille), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style(espaceAvant: 0, espaceApres: 6)]
        var couleurParNom: [String: NSColor] = [:]
        let resultat = NSMutableAttributedString()

        for ligne in texte.components(separatedBy: "\n") where !ligne.trimmingCharacters(in: .whitespaces).isEmpty {
            let ns = ligne as NSString
            var replique = ligne
            if let m = prefixe.firstMatch(in: ligne, range: NSRange(location: 0, length: ns.length)) {
                let nom = ns.substring(with: m.range(at: 1))
                replique = ns.substring(from: m.range.upperBound)
                let couleur = couleurParNom[nom] ?? couleurs[couleurParNom.count % couleurs.count]
                couleurParNom[nom] = couleur
                if resultat.length > 0 { resultat.append(NSAttributedString(string: "\n")) }
                resultat.append(NSAttributedString(string: nom + "\n", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: taille - 1), .foregroundColor: couleur,
                    .paragraphStyle: style(espaceAvant: resultat.length > 0 ? 16 : 0, espaceApres: 3)]))
            } else if resultat.length > 0 {
                resultat.append(NSAttributedString(string: "\n"))
            }
            resultat.append(NSAttributedString(string: paragraphes(replique).joined(separator: "\n"), attributes: corps))
        }
        return resultat
    }

    /// Coupe une longue réplique en paragraphes d'environ 400 caractères, entre deux phrases.
    private static func paragraphes(_ replique: String) -> [String] {
        guard replique.count > 500 else { return [replique] }
        let ns = replique as NSString
        var phrases: [String] = []
        var debut = 0
        for m in finDePhrase.matches(in: replique, range: NSRange(location: 0, length: ns.length)) {
            phrases.append(ns.substring(with: NSRange(location: debut, length: m.range.location - debut)))
            debut = m.range.upperBound
        }
        phrases.append(ns.substring(from: debut))
        var blocs: [String] = []
        var courant = ""
        for phrase in phrases {
            courant += (courant.isEmpty ? "" : " ") + phrase
            if courant.count >= 400 { blocs.append(courant); courant = "" }
        }
        if !courant.isEmpty {
            if courant.count < 120, let dernier = blocs.popLast() { blocs.append(dernier + " " + courant) } else { blocs.append(courant) }
        }
        return blocs
    }

    private static func style(espaceAvant: CGFloat, espaceApres: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = espaceAvant
        style.paragraphSpacing = espaceApres
        return style
    }
}

/// Markdown simple des résumés -> texte mis en forme : titres, listes (avec retrait), paragraphes ;
/// gras, italique et code en ligne.
enum Markdown {
    static func enAttribue(_ markdown: String) -> NSAttributedString {
        let resultat = NSMutableAttributedString()
        let taille = NSFont.systemFontSize
        for ligne in markdown.components(separatedBy: "\n") {
            let propre = ligne.trimmingCharacters(in: .whitespaces)
            guard !propre.isEmpty, propre != "---" else { continue }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 5
            var police = NSFont.systemFont(ofSize: taille)
            var contenu = propre

            if let diese = propre.range(of: #"^#{1,6} "#, options: .regularExpression) {
                let niveau = propre[diese].count - 1
                police = .boldSystemFont(ofSize: niveau <= 1 ? taille + 7 : niveau == 2 ? taille + 4 : taille + 1)
                style.paragraphSpacingBefore = niveau <= 2 ? 12 : 6
                contenu = String(propre[diese.upperBound...])
            } else {
                let retrait = CGFloat(ligne.prefix { $0 == " " || $0 == "\t" }.count / 2) * 18
                var marque: String?
                if let m = propre.range(of: #"^[-*+] "#, options: .regularExpression) {
                    marque = "•"
                    contenu = String(propre[m.upperBound...])
                } else if let m = propre.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                    marque = String(propre[m].dropLast())
                    contenu = String(propre[m.upperBound...])
                }
                if let marque {
                    // Puce, tabulation, texte aligné sur la tabulation (y compris les lignes suivantes)
                    style.firstLineHeadIndent = retrait + 4
                    style.headIndent = retrait + 22
                    style.tabStops = [NSTextTab(textAlignment: .left, location: retrait + 22)]
                    contenu = "\(marque)\t\(contenu)"
                }
            }
            if resultat.length > 0 { resultat.append(NSAttributedString(string: "\n")) }
            let morceau = enLigne(contenu, police: police)
            morceau.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: morceau.length))
            resultat.append(morceau)
        }
        return resultat
    }

    /// Gras, italique et code en ligne, convertis en polices AppKit.
    private static func enLigne(_ texte: String, police: NSFont) -> NSMutableAttributedString {
        let sortie = NSMutableAttributedString()
        guard let analyse = try? AttributedString(markdown: texte, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: texte, attributes: [.font: police, .foregroundColor: NSColor.labelColor])
        }
        for run in analyse.runs {
            let intention = run.inlinePresentationIntent ?? []
            var p = police
            if intention.contains(.code) {
                p = .monospacedSystemFont(ofSize: police.pointSize - 1, weight: .regular)
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intention.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intention.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                p = NSFont(descriptor: p.fontDescriptor.withSymbolicTraits(p.fontDescriptor.symbolicTraits.union(traits)), size: p.pointSize) ?? p
            }
            var attributs: [NSAttributedString.Key: Any] = [.font: p, .foregroundColor: NSColor.labelColor]
            if let lien = run.link { attributs[.link] = lien }
            sortie.append(NSAttributedString(string: String(analyse[run.range].characters), attributes: attributs))
        }
        return sortie
    }
}

/// Feuille « Résumé IA » : format (par défaut celui de la catégorie de l'appel) et prompt prérempli,
/// modifiable pour ce résumé seulement.
struct FeuilleResume: View {
    let appel: Appel
    @ObservedObject var prompts: Prompts
    let resumeExiste: Bool
    let locuteursAValider: Bool
    let ouvrirPrompts: () -> Void
    let generer: (FormatResume, String?) -> Void
    @Environment(\.dismiss) private var fermer
    @State private var format: FormatResume
    @State private var texte = ""

    init(appel: Appel, prompts: Prompts, resumeExiste: Bool, locuteursAValider: Bool,
         ouvrirPrompts: @escaping () -> Void, generer: @escaping (FormatResume, String?) -> Void) {
        self.appel = appel
        self.prompts = prompts
        self.resumeExiste = resumeExiste
        self.locuteursAValider = locuteursAValider
        self.ouvrirPrompts = ouvrirPrompts
        self.generer = generer
        _format = State(initialValue: FormatResume(categorie: appel.categorie))
    }

    private var base: String { prompts.prompt(format) }
    private var personnalise: Bool {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Résumé IA — \(appel.nom)").font(.headline).lineLimit(1)
            Picker("Format", selection: $format) {
                ForEach(FormatResume.allCases) { f in Text(f.titre).tag(f) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Prompt").font(.subheadline.bold())
                if personnalise {
                    Text("modifié pour ce résumé").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(prompts.estModifie(format) ? "ton prompt de base (modifié dans Prompts)" : "prompt d'origine")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annuler mes modifications") { texte = base }
                    .disabled(!personnalise)
                    .help("Revient au prompt de base de ce format, tel qu'il est dans la fenêtre Prompts")
            }
            TextEditor(text: $texte)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Button("Modifier les prompts de base (ou rétablir ceux d'origine)…", action: ouvrirPrompts).buttonStyle(.link).font(.caption)
            if locuteursAValider {
                Label("Les locuteurs ne sont pas encore validés : le résumé sera plus juste après validation.",
                      systemImage: "person.2.badge.gearshape").font(.caption).foregroundStyle(.secondary)
            }
            if resumeExiste {
                Label("Le résumé actuel de cet appel sera remplacé.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Annuler") { fermer() }.keyboardShortcut(.cancelAction)
                Button(resumeExiste ? "Remplacer le résumé" : "Générer") {
                    generer(format, personnalise ? texte : nil)
                    fermer()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 580, height: 480)
        .onAppear { texte = base }
        .onChange(of: format) { _, _ in texte = base }
    }
}

struct VueTranscript: View {
    enum Onglet: Hashable { case transcript, resume }

    let appel: Appel
    @ObservedObject var historique: Historique
    @ObservedObject var prompts: Prompts
    let peutModifier: Bool
    @Binding var editionNom: Bool
    let renommer: (String) -> Void
    let supprimer: () -> Void
    let definirCategorie: (Categorie?) -> Void
    let validerProposition: ([String: String], String, Categorie?) -> Void
    let ignorerProposition: () -> Void
    let ouvrirPrompts: () -> Void
    @State private var texte = ""
    @State private var resume = ""
    @State private var resumeMisEnForme = NSAttributedString()
    @State private var texteMisEnForme = NSAttributedString()  // calculé une fois par lecture, pas à chaque rendu
    @State private var onglet: Onglet = .transcript
    @State private var feuilleResume = false

    private var proposition: Proposition? { historique.propositions[appel.fichier] }
    private var resumeEnCours: Bool { historique.resumesEnCours.contains(appel.fichier) }
    private var aUnResume: Bool { historique.resumes.contains(appel.fichier) }
    private var erreurResume: String? { historique.erreursResume[appel.fichier] }
    private var nettoyageEnCours: Bool { historique.nettoyagesEnCours.contains(appel.fichier) }
    private var tacheEnCours: Bool { resumeEnCours || nettoyageEnCours }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // En-tête sur deux lignes : le titre a toute la largeur ; date, catégorie et actions en dessous
            VStack(alignment: .leading, spacing: 6) {
                NomModifiable(nom: appel.nom, police: .title3.bold(), peutRenommer: peutModifier && !tacheEnCours,
                              edition: $editionNom, valider: renommer)
                HStack(spacing: 8) {
                    Text(appel.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    if appel.etat == .pret {
                        Menu {
                            ChoixCategorie(categorie: appel.categorie, choisir: definirCategorie)
                        } label: {
                            Label(appel.categorie?.titre ?? "Non classé", systemImage: appel.categorie?.icone ?? "tag")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Catégorie de l'appel")
                    }
                    Spacer(minLength: 12)
                    // Libellés complets si la place le permet, sinon icônes seules (jamais de bouton tronqué)
                    ViewThatFits(in: .horizontal) {
                        actions(compact: false)
                        actions(compact: true)
                    }
                }
            }
            .padding()
            if let proposition, appel.etat == .pret {
                Divider()
                PanneauValidation(proposition: proposition, categorieActuelle: appel.categorie,
                                  candidat: historique.reglages.candidat, actif: peutModifier,
                                  valider: validerProposition, ignorer: ignorerProposition)
                    .id(appel.id)  // champs remis à zéro quand on change d'appel
            }
            if appel.etat == .pret {
                Picker("", selection: $onglet) {
                    Text("Transcript").tag(Onglet.transcript)
                    Text("Résumé").tag(Onglet.resume)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            if appel.etat == .pret && onglet == .transcript {
                bandeauNettoyage
            }
            Divider()
            switch appel.etat {
            case .pret where onglet == .resume:
                ongletResume
            case .pret:
                TexteDefilant(texteMisEnForme)
            case .enCours:
                VStack(spacing: 10) {
                    Text("Transcription en cours (environ la moitié de la durée de l'appel)").foregroundStyle(.secondary)
                    DetailProgression(progression: historique.progression).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .enAttente:
                Text("En attente de transcription.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(appel.id.path)|\(proposition == nil)|\(nettoyageEnCours)") {  // relu après validation et nettoyage
            texte = appel.etat == .pret ? ((try? String(contentsOf: appel.id, encoding: .utf8)) ?? "") : ""
            texteMisEnForme = MiseEnFormeTranscript.enAttribue(texte)
        }
        .task(id: "\(appel.fichier)|\(aUnResume)|\(resumeEnCours)") {  // relu aussi à la fin d'une génération
            resume = aUnResume ? ((try? String(contentsOf: historique.urlResume(appel), encoding: .utf8)) ?? "") : ""
            resumeMisEnForme = Markdown.enAttribue(resume)
        }
        .onChange(of: appel.fichier) { _, _ in onglet = .transcript }
        .sheet(isPresented: $feuilleResume) {
            FeuilleResume(appel: appel, prompts: prompts, resumeExiste: aUnResume,
                          locuteursAValider: proposition.map { !$0.locuteurs.isEmpty } ?? false,
                          ouvrirPrompts: ouvrirPrompts) { format, prompt in
                historique.genererResume(appel, format: format, prompt: prompt)
                onglet = .resume
            }
        }
    }

    /// Boutons d'action de l'en-tête ; en mode compact, icônes seules (le libellé reste dans l'info-bulle).
    @ViewBuilder private func actions(compact: Bool) -> some View {
        if compact {
            rangeeActions.labelStyle(.iconOnly).fixedSize()
        } else {
            rangeeActions.labelStyle(.titleAndIcon).fixedSize()
        }
    }

    private var rangeeActions: some View {
        HStack(spacing: 8) {
            if appel.etat == .pret {
                if historique.nettoyes.contains(appel.fichier) {
                    // Badge non cliquable à la place du bouton, exactement à sa taille (bouton invisible dessous)
                    Button {} label: { Label("Nettoyer", systemImage: "wand.and.stars") }
                        .hidden()
                        .overlay {
                            Label("Nettoyé", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.15)))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(0.5)))
                        }
                        .help("Transcript corrigé par Claude Haiku ; la version brute est gardée (clic droit sur l'appel dans la liste pour la voir ou renettoyer)")
                } else {
                    Button { historique.nettoyer(appel) } label: { Label("Nettoyer", systemImage: "wand.and.stars") }
                        .disabled(tacheEnCours)
                        .help("Corriger les erreurs de reconnaissance avec Claude Haiku (~1 centime). Le brut est gardé.")
                }
                Button { feuilleResume = true } label: { Label("Résumé IA", systemImage: "sparkles") }
                    .disabled(tacheEnCours)
                    .help(resumeEnCours ? "Résumé en cours…" : nettoyageEnCours ? "Attends la fin du nettoyage" : "Générer un résumé de cet appel")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(onglet == .resume ? resume : texte, forType: .string)
                } label: { Label("Copier", systemImage: "doc.on.doc") }
                    .disabled(onglet == .resume && resume.isEmpty)
                    .help(onglet == .resume ? "Copier le résumé" : "Copier le transcript")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([onglet == .resume && aUnResume ? historique.urlResume(appel) : appel.id])
            } label: { Label("Afficher dans le Finder", systemImage: "folder") }
                .help("Afficher dans le Finder")
            Button(action: supprimer) { Label("Corbeille", systemImage: "trash") }
                .labelStyle(.iconOnly)
                .disabled(!peutModifier || appel.etat == .enCours || tacheEnCours)
                .help("Mettre à la corbeille")
        }
    }

    /// Pendant le nettoyage : étape et temps écoulé ; après un échec : le message.
    @ViewBuilder private var bandeauNettoyage: some View {
        if nettoyageEnCours {
            TimelineView(.periodic(from: .now, by: 1)) { contexte in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let etape = historique.etapeTache(appel.fichier) {
                        let ecoule = Int(contexte.date.timeIntervalSince(etape.debut))
                        Text("\(etape.texte) · \(ecoule) s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Nettoyage du transcript…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal).padding(.bottom, 6)
            }
        } else if let erreur = historique.erreursNettoyage[appel.fichier] {
            Label("Nettoyage impossible : \(erreur)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                .padding(.horizontal).padding(.bottom, 6)
        }
    }

    @ViewBuilder private var ongletResume: some View {
        if resumeEnCours {
            TimelineView(.periodic(from: .now, by: 1)) { contexte in
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Résumé en cours").font(.headline)
                    if let etape = historique.etapeTache(appel.fichier) {
                        let ecoule = Int(contexte.date.timeIntervalSince(etape.debut))
                        Text(etape.texte).foregroundStyle(.secondary)
                        Text(ecoule < 60 ? "\(ecoule) s" : "\(ecoule / 60) min \(String(format: "%02d", ecoule % 60)) s")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !resume.isEmpty || erreurResume != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let erreurResume {
                    Label("Le dernier résumé a échoué : \(erreurResume)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled).padding()
                }
                TexteDefilant(resumeMisEnForme)
            }
        } else {
            VStack(spacing: 10) {
                Text("Pas encore de résumé pour cet appel.").foregroundStyle(.secondary)
                Button { feuilleResume = true } label: { Label("Générer un résumé IA", systemImage: "sparkles") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FenetrePrincipale: View {
    @ObservedObject var historique: Historique
    @ObservedObject var prompts: Prompts
    let surImport: () -> Void
    let ouvrirJournal: () -> Void
    let ouvrirPrompts: () -> Void
    @State private var selection: Appel.ID?
    @AppStorage("tri") private var tri: Tri = .recents
    @AppStorage("filtre") private var filtre: Filtre = .tous
    /// Appel dont le nom est en cours de modification, et où (liste ou en-tête du transcript)
    @State private var edition: (id: Appel.ID, dansListe: Bool)?
    @State private var erreur: (titre: String, message: String)?

    /// Appels de la liste : filtrés par catégorie, puis triés
    private var visibles: [Appel] { tri.trier(historique.appels.filter(filtre.garde)) }

    var body: some View {
        VStack(spacing: 0) {
            if historique.transcriptionEnCours {
                BandeauTranscription(historique: historique, ouvrirJournal: ouvrirJournal)
            }
            ZoneDeDepot(historique: historique, surImport: surImport)
            NavigationSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(visibles.count) appel\(visibles.count > 1 ? "s" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Filtrer", selection: $filtre) {
                            ForEach(Filtre.allCases) { Text($0.titre).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        Picker("Trier", selection: $tri) {
                            ForEach(Tri.allCases) { Text($0.titre).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    liste
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            } detail: {
                if let appel = historique.appels.first(where: { $0.id == selection }) {
                    VueTranscript(appel: appel, historique: historique, prompts: prompts,
                                  peutModifier: !historique.transcriptionEnCours,
                                  editionNom: enEdition(appel, dansListe: false),
                                  renommer: { renommer(appel, en: $0) },
                                  supprimer: { supprimer(appel) },
                                  definirCategorie: { historique.definirCategorie(appel, $0) },
                                  validerProposition: { valider(appel, noms: $0, nom: $1, categorie: $2) },
                                  ignorerProposition: { ignorerProposition(appel) },
                                  ouvrirPrompts: ouvrirPrompts)
                    .frame(minWidth: 460)
                } else {
                    Text("Choisis un appel à gauche").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { selection = selection ?? visibles.first?.id }
        .onChange(of: historique.appels) { _, appels in
            // Fin de transcription ou renommage : l'appel sélectionné change d'identifiant, on le suit par son nom
            if let actuelle = selection, !appels.contains(where: { $0.id == actuelle }) {
                let fichier = actuelle.deletingPathExtension().lastPathComponent
                selection = appels.first { $0.fichier == fichier }?.id
            }
        }
        .onChange(of: filtre) { _, _ in
            if !visibles.contains(where: { $0.id == selection }) { selection = visibles.first?.id }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in historique.recharger() }
        .alert(erreur?.titre ?? "", isPresented: Binding(get: { erreur != nil }, set: { if !$0 { erreur = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(erreur?.message ?? "")
        }
    }

    private var liste: some View {
        List(visibles, selection: $selection) { appel in
            VStack(alignment: .leading, spacing: 2) {
                NomModifiable(nom: appel.nom, police: .body, peutRenommer: !historique.transcriptionEnCours,
                              edition: enEdition(appel, dansListe: true), valider: { renommer(appel, en: $0) })
                HStack(spacing: 4) {
                    switch appel.etat {
                    case .pret:
                        if let categorie = appel.categorie {
                            Image(systemName: categorie.icone).foregroundStyle(.secondary).help(categorie.titre)
                        }
                        if historique.propositions[appel.fichier] != nil {
                            Image(systemName: "person.2.badge.gearshape").foregroundStyle(.tint).help("Locuteurs et nom à valider")
                        }
                        if historique.nettoyagesEnCours.contains(appel.fichier) {
                            ProgressView().controlSize(.mini).help("Nettoyage en cours")
                        } else if historique.nettoyes.contains(appel.fichier) {
                            Image(systemName: "checkmark.seal").foregroundStyle(.secondary).help("Transcript nettoyé")
                        }
                        if historique.resumesEnCours.contains(appel.fichier) {
                            ProgressView().controlSize(.mini).help("Résumé en cours")
                        } else if historique.resumes.contains(appel.fichier) {
                            Image(systemName: "sparkles").foregroundStyle(.secondary).help("Résumé IA disponible")
                        }
                    case .enCours: Image(systemName: "waveform").foregroundStyle(.orange); Text("En cours").foregroundStyle(.orange)
                    case .enAttente: Image(systemName: "clock").foregroundStyle(.secondary); Text("En attente")
                    }
                    Text(appel.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 2)
        }
        .contextMenu(forSelectionType: Appel.ID.self) { ids in
            if let appel = ids.first.flatMap(trouver) {
                Button("Renommer") { edition = (appel.id, true) }.disabled(historique.transcriptionEnCours)
                if appel.etat == .pret {
                    Menu("Catégorie") {
                        ChoixCategorie(categorie: appel.categorie) { historique.definirCategorie(appel, $0) }
                    }
                }
                if appel.etat == .pret {
                    Button(historique.nettoyes.contains(appel.fichier) ? "Nettoyer à nouveau (depuis le brut)" : "Nettoyer le transcript") {
                        historique.nettoyer(appel)
                    }
                    .disabled(historique.nettoyagesEnCours.contains(appel.fichier) || historique.resumesEnCours.contains(appel.fichier))
                    if historique.nettoyes.contains(appel.fichier) {
                        Button("Afficher le brut dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([historique.urlBrut(appel)])
                        }
                    }
                }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([appel.id]) }
                Divider()
                Button("Mettre à la corbeille") { supprimer(appel) }
                    .disabled(historique.transcriptionEnCours || appel.etat == .enCours)
            }
        } primaryAction: { ids in
            // Double-clic sur une ligne : renommage sur place
            if let id = ids.first, !historique.transcriptionEnCours { edition = (id, true) }
        }
        .onDeleteCommand {
            if edition == nil, let appel = selection.flatMap(trouver) { supprimer(appel) }
        }
        .overlay {
            if visibles.isEmpty {
                Text(historique.appels.isEmpty ? "Aucun appel pour l'instant" : "Aucun appel dans cette catégorie")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trouver(_ id: Appel.ID) -> Appel? {
        historique.appels.first { $0.id == id }
    }

    private func enEdition(_ appel: Appel, dansListe: Bool) -> Binding<Bool> {
        Binding(
            get: { edition?.id == appel.id && edition?.dansListe == dansListe },
            set: { actif in
                if actif {
                    edition = (appel.id, dansListe)
                } else if edition?.id == appel.id && edition?.dansListe == dansListe {
                    edition = nil
                }
            })
    }

    private func renommer(_ appel: Appel, en nom: String) {
        do {
            let nouvelId = try historique.renommer(appel, en: nom)
            if selection == appel.id { selection = nouvelId }
        } catch {
            erreur = ("Renommage impossible", error.localizedDescription)
        }
    }

    private func valider(_ appel: Appel, noms: [String: String], nom: String, categorie: Categorie?) {
        do {
            let nouvelId = try historique.valider(appel, noms: noms, nom: nom, categorie: categorie)
            if selection == appel.id { selection = nouvelId }
            // Noms validés : nettoyage automatique du transcript (Claude Haiku), sauf s'il est déjà fait
            if let valide = trouver(nouvelId), !historique.nettoyes.contains(valide.fichier) { historique.nettoyer(valide) }
        } catch {
            erreur = ("Validation impossible", error.localizedDescription)
        }
    }

    private func ignorerProposition(_ appel: Appel) {
        do {
            try historique.ignorerProposition(appel)
            if !historique.nettoyes.contains(appel.fichier) { historique.nettoyer(appel) }
        } catch {
            erreur = ("Action impossible", error.localizedDescription)
        }
    }

    /// Envoie l'appel dans la corbeille (dossier Corbeille du projet) et sélectionne le suivant.
    private func supprimer(_ appel: Appel) {
        let ordre = visibles
        let suivant = ordre.firstIndex(of: appel).flatMap { i in
            i + 1 < ordre.count ? ordre[i + 1] : (i > 0 ? ordre[i - 1] : nil)
        }
        do {
            try historique.mettreALaCorbeille(appel)
            if selection == appel.id { selection = suivant?.id }
        } catch {
            erreur = ("Suppression impossible", error.localizedDescription)
        }
    }
}
