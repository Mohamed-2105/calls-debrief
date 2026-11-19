// Catégories d'appels, formats de résumé IA et prompts de base (modifiables dans la fenêtre Prompts).

import SwiftUI

/// Type d'appel : proposé par Gemini à la fin de la transcription, modifiable dans l'app, sert au filtre de la liste.
enum Categorie: String, CaseIterable, Identifiable {
    case entretien, pro, perso
    var id: String { rawValue }
    var titre: String {
        switch self {
        case .entretien: return "Entretien"
        case .pro: return "Call pro"
        case .perso: return "Call perso"
        }
    }
    var icone: String {
        switch self {
        case .entretien: return "person.crop.rectangle"
        case .pro: return "briefcase"
        case .perso: return "heart"
        }
    }
}

/// Format d'un résumé : un par catégorie, plus Neutre. Mêmes clés que PROMPTS_DEFAUT dans calls_debrief/resume.py.
enum FormatResume: String, CaseIterable, Identifiable {
    case entretien, pro, perso, neutre
    var id: String { rawValue }
    var titre: String { Categorie(rawValue: rawValue)?.titre ?? "Neutre" }
    var icone: String { Categorie(rawValue: rawValue)?.icone ?? "text.alignleft" }

    init(categorie: Categorie?) {
        self = categorie.flatMap { FormatResume(rawValue: $0.rawValue) } ?? .neutre
    }
}

/// Prompts de base des résumés : défauts inscrits dans Info.plist, modifications dans .etat/prompts.json
/// (lu par calls_debrief/resume.py). Seuls les prompts différents du défaut y sont écrits.
final class Prompts: ObservableObject {
    @Published private(set) var modifies: [String: String] = [:]
    /// Ton profil (parcours, objectifs…), ajouté au contexte de chaque résumé par calls_debrief/resume.py
    @Published private(set) var profil = ""
    let reglages: Reglages

    init(reglages: Reglages) {
        self.reglages = reglages
        recharger()
    }

    func recharger() {
        profil = (try? String(contentsOf: reglages.profil, encoding: .utf8)) ?? ""
        guard let data = try? Data(contentsOf: reglages.prompts),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            modifies = [:]
            return
        }
        modifies = json
    }

    func defaut(_ format: FormatResume) -> String { reglages.promptsDefaut[format.rawValue] ?? "" }

    func prompt(_ format: FormatResume) -> String {
        let modifie = (modifies[format.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return modifie.isEmpty ? defaut(format) : modifie
    }

    func estModifie(_ format: FormatResume) -> Bool { prompt(format) != defaut(format) }

    func definir(_ format: FormatResume, _ texte: String) {
        let propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        if propre.isEmpty || propre == defaut(format) {
            modifies[format.rawValue] = nil
        } else {
            modifies[format.rawValue] = texte
        }
        enregistrer()
    }

    func definirProfil(_ texte: String) {
        profil = texte
        try? FileManager.default.createDirectory(at: reglages.profil.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? texte.write(to: reglages.profil, atomically: true, encoding: .utf8)
    }

    private func enregistrer() {
        try? FileManager.default.createDirectory(at: reglages.prompts.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: modifies, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reglages.prompts, options: .atomic)
        }
    }
}

/// Fenêtre « Prompts des résumés » : un prompt de base par format, plus ton profil ; enregistrés à chaque frappe.
struct FenetrePrompts: View {
    enum Onglet: Hashable {
        case format(FormatResume)
        case profil
    }

    @ObservedObject var prompts: Prompts
    @State private var onglet: Onglet = .format(.entretien)
    @State private var texte = ""

    private static let aideProfil = """
    Quelques lignes sur toi, ajoutées au contexte de chaque résumé pour que l'analyse soit pertinente pour toi. Par exemple :
    – ton parcours (études, expériences marquantes) ;
    – ce que tu cherches (type de poste, secteur, entreprises visées, dates) ;
    – tes projets et réalisations à valoriser ;
    – tes points d'amélioration connus en entretien.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Onglet", selection: $onglet) {
                ForEach(FormatResume.allCases) { f in
                    Text(prompts.estModifie(f) ? "\(f.titre) •" : f.titre).tag(Onglet.format(f))
                }
                Text("Mon profil").tag(Onglet.profil)
            }
            .pickerStyle(.segmented).labelsHidden()
            switch onglet {
            case .format(let format):
                Text("Prompt de base « \(format.titre) »\(prompts.estModifie(format) ? " (modifié)" : "")").font(.headline)
                Text("Proposé quand tu génères un résumé de ce format ; tu peux encore le modifier pour un résumé donné. Les consignes de mise en forme (Markdown, français, ne rien inventer), ton profil et la transcription sont ajoutés automatiquement. Enregistré à chaque frappe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .profil:
                Text("Mon profil").font(.headline)
                Text("Ajouté à tous les résumés (Claude, Gemini ou OVHcloud). Environ 0,1 à 0,2 centime de plus par résumé avec Claude Sonnet. Enregistré à chaque frappe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $texte)
                .font(onglet == .profil ? .body : .body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if onglet == .profil && texte.isEmpty {
                        Text(Self.aideProfil).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
                .onChange(of: texte) { _, nouveau in enregistrer(nouveau) }
            if case .format(let format) = onglet {
                HStack {
                    Spacer()
                    Button("Rétablir le prompt par défaut") { texte = prompts.defaut(format) }
                        .disabled(!prompts.estModifie(format))
                }
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 400)
        .onAppear { texte = contenu(onglet) }
        .onChange(of: onglet) { _, o in texte = contenu(o) }
    }

    private func contenu(_ onglet: Onglet) -> String {
        switch onglet {
        case .format(let f): return prompts.prompt(f)
        case .profil: return prompts.profil
        }
    }

    private func enregistrer(_ nouveau: String) {
        guard nouveau != contenu(onglet) else { return }
        switch onglet {
        case .format(let f): prompts.definir(f, nouveau)
        case .profil: prompts.definirProfil(nouveau)
        }
    }
}
