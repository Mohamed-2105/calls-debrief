// Fenêtre principale : dépôt d'enregistrements (iPhone, Dictaphone…), avancement de la transcription
// et historique des transcripts (tri, renommage sur place, corbeille).

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

enum ErreurFichiers: LocalizedError {
    case nomVide, dejaPris(String), transcriptionEnCours(String)

    var errorDescription: String? {
        switch self {
        case .nomVide: return "Le nom ne peut pas être vide."
        case .dejaPris(let nom): return "Un fichier « \(nom) » existe déjà."
        case .transcriptionEnCours(let action): return "Attends la fin de la transcription en cours pour \(action)."
        }
    }
}

final class Historique: ObservableObject {
    @Published var appels: [Appel] = []
    @Published var transcriptionEnCours = false
    @Published var progression: Progression?
    let reglages: Reglages

    /// Dates des appels, mémorisées dans 03_Transcripts/.calls-debrief.json : la date de modification des fichiers
    /// change dès qu'ils sont copiés ou retranscrits, elle ne dit pas quand l'appel a eu lieu.
    private var dates: [String: Date] = [:]
    private var datesEnCalcul: Set<String> = []
    private var fichierDates: URL { reglages.transcripts.appendingPathComponent(".calls-debrief.json") }

    init(reglages: Reglages) {
        self.reglages = reglages
        chargerDates()
        recharger()
    }

    // MARK: Liste

    private func fichiers(_ dossier: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dossier, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
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
    }

    private func creerAppel(id: URL, etat: Appel.Etat) -> Appel {
        let fichier = id.deletingPathExtension().lastPathComponent
        let date = dates[fichier] ?? Self.dateDepuisNom(fichier) ?? Self.dateDeCreation(id) ?? .distantPast
        if dates[fichier] == nil { resoudreDate(fichier) }
        return Appel(id: id, fichier: fichier, nom: Self.joli(fichier), date: date, etat: etat)
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

    private func chargerDates() {
        guard let data = try? Data(contentsOf: fichierDates),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let brutes = json["dates"] as? [String: Double] else { return }
        dates = brutes.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func enregistrerDates() {
        let json: [String: Any] = ["dates": dates.mapValues { $0.timeIntervalSince1970 }]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fichierDates, options: .atomic)
        }
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
                self.enregistrerDates()
                self.recharger()
            }
        }
    }

    // MARK: Fichiers d'un appel

    /// Tous les fichiers d'un appel : transcript, audio (à traiter et archivé) et cache de transcription.
    /// `suite` est ce qui suit le nom : ".txt", ou ".m4a_1234.txt" / ".m4a_1234.segments.json" pour le cache.
    private func fichiersLies(_ nom: String) -> [(fichier: URL, dossier: URL, suite: String)] {
        var liste: [(URL, URL, String)] = []
        for dossier in [reglages.transcripts, reglages.aTraiter, reglages.archives] {
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
        var nouveau = saisie.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while nouveau.hasPrefix(".") { nouveau.removeFirst() }
        guard !nouveau.isEmpty else { throw ErreurFichiers.nomVide }
        let ancien = appel.fichier
        guard nouveau != ancien else { return appel.id }

        let deplacements = fichiersLies(ancien).map { ($0.fichier, $0.dossier.appendingPathComponent(nouveau + $0.suite)) }
        let fm = FileManager.default
        for (source, destination) in deplacements where fm.fileExists(atPath: destination.path)
            && source.path.lowercased() != destination.path.lowercased() {  // simple changement de casse : autorisé
            throw ErreurFichiers.dejaPris(destination.lastPathComponent)
        }
        try deplacer(deplacements)

        dates[nouveau] = dates[ancien] ?? appel.date  // garde la date même si le nom "appel_…" la portait
        dates[ancien] = nil
        enregistrerDates()
        recharger()
        let ext = appel.id.pathExtension
        return appel.id.deletingLastPathComponent().appendingPathComponent(nouveau).appendingPathExtension(ext)
    }

    // MARK: Corbeille

    /// Déplace tous les fichiers de l'appel dans Corbeille/<nom> — <date>/, rangés par dossier d'origine
    /// (03_Transcripts, 01_A_Traiter, 02_Archives, cache) : pour restaurer, il suffit de les remettre en place.
    func mettreALaCorbeille(_ appel: Appel) throws {
        guard !transcriptionEnCours else { throw ErreurFichiers.transcriptionEnCours("supprimer") }
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
            let sousDossier = dossier.appendingPathComponent(origine == reglages.cache ? "cache" : origine.lastPathComponent)
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
        enregistrerDates()
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

struct VueTranscript: View {
    let appel: Appel
    let progression: Progression?
    let peutModifier: Bool
    @Binding var editionNom: Bool
    let renommer: (String) -> Void
    let supprimer: () -> Void
    @State private var texte = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    NomModifiable(nom: appel.nom, police: .title3.bold(), peutRenommer: peutModifier,
                                  edition: $editionNom, valider: renommer)
                    Text(appel.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if appel.etat == .pret {
                    Button("Copier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(texte, forType: .string)
                    }
                }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([appel.id]) }
                Button(action: supprimer) { Image(systemName: "trash") }
                    .disabled(!peutModifier || appel.etat == .enCours)
                    .help("Mettre à la corbeille")
            }
            .padding()
            Divider()
            switch appel.etat {
            case .pret:
                ScrollView {
                    Text(texte).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            case .enCours:
                VStack(spacing: 10) {
                    Text("Transcription en cours (environ la moitié de la durée de l'appel)").foregroundStyle(.secondary)
                    DetailProgression(progression: progression).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .enAttente:
                Text("En attente de transcription.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: appel) {
            texte = appel.etat == .pret ? ((try? String(contentsOf: appel.id, encoding: .utf8)) ?? "") : ""
        }
    }
}

struct FenetrePrincipale: View {
    @ObservedObject var historique: Historique
    let surImport: () -> Void
    let ouvrirJournal: () -> Void
    @State private var selection: Appel.ID?
    @AppStorage("tri") private var tri: Tri = .recents
    /// Appel dont le nom est en cours de modification, et où (liste ou en-tête du transcript)
    @State private var edition: (id: Appel.ID, dansListe: Bool)?
    @State private var erreur: (titre: String, message: String)?

    var body: some View {
        VStack(spacing: 0) {
            if historique.transcriptionEnCours {
                BandeauTranscription(historique: historique, ouvrirJournal: ouvrirJournal)
            }
            ZoneDeDepot(historique: historique, surImport: surImport)
            NavigationSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(historique.appels.count) appel\(historique.appels.count > 1 ? "s" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Trier", selection: $tri) {
                            ForEach(Tri.allCases) { Text($0.titre).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    liste
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            } detail: {
                if let appel = historique.appels.first(where: { $0.id == selection }) {
                    VueTranscript(appel: appel, progression: historique.progression,
                                  peutModifier: !historique.transcriptionEnCours,
                                  editionNom: enEdition(appel, dansListe: false),
                                  renommer: { renommer(appel, en: $0) },
                                  supprimer: { supprimer(appel) })
                } else {
                    Text("Choisis un appel à gauche").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear { selection = selection ?? tri.trier(historique.appels).first?.id }
        .onChange(of: historique.appels) { _, appels in
            // Fin de transcription ou renommage : l'appel sélectionné change d'identifiant, on le suit par son nom
            if let actuelle = selection, !appels.contains(where: { $0.id == actuelle }) {
                let fichier = actuelle.deletingPathExtension().lastPathComponent
                selection = appels.first { $0.fichier == fichier }?.id
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in historique.recharger() }
        .alert(erreur?.titre ?? "", isPresented: Binding(get: { erreur != nil }, set: { if !$0 { erreur = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(erreur?.message ?? "")
        }
    }

    private var liste: some View {
        List(tri.trier(historique.appels), selection: $selection) { appel in
            VStack(alignment: .leading, spacing: 2) {
                NomModifiable(nom: appel.nom, police: .body, peutRenommer: !historique.transcriptionEnCours,
                              edition: enEdition(appel, dansListe: true), valider: { renommer(appel, en: $0) })
                HStack(spacing: 4) {
                    switch appel.etat {
                    case .pret: EmptyView()
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
            if historique.appels.isEmpty {
                Text("Aucun appel pour l'instant").foregroundStyle(.secondary)
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

    /// Envoie l'appel dans la corbeille (dossier Corbeille du projet) et sélectionne le suivant.
    private func supprimer(_ appel: Appel) {
        let ordre = tri.trier(historique.appels)
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
