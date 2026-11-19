// App de la barre des menus : détecte les appels, enregistre (son de l'ordi + micro),
// puis lance la transcription automatiquement à l'arrêt.
// Les chemins du projet sont inscrits dans Info.plist au moment de l'installation (python installer_app.py).

import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Réglages inscrits à l'installation

struct Reglages {
    let projet: URL
    let python: URL
    let bruts: URL
    let aTraiter: URL
    let transcripts: URL
    let resumes: URL       // 04_Resumes : résumés IA (Markdown), un par appel
    let archives: URL
    let cache: URL
    let journaux: URL
    let progression: URL
    let propositions: URL  // noms des locuteurs et de l'appel, préremplis par Gemini, à valider
    let candidat: String   // CANDIDATE_NAME : premier nom suggéré dans le panneau de validation
    let corbeille: URL
    let dureeCorbeille: Int  // jours avant suppression définitive
    let prompts: URL         // prompts des résumés modifiés dans l'app
    let profil: URL          // ton profil (Markdown), ajouté au contexte des résumés
    let promptsDefaut: [String: String]

    static func lire() -> Reglages {
        let info = Bundle.main.infoDictionary ?? [:]
        func chemin(_ cle: String) -> URL {
            guard let valeur = info[cle] as? String else { fatalError("Clé \(cle) absente d'Info.plist : réinstalle l'app.") }
            return URL(fileURLWithPath: valeur)
        }
        return Reglages(
            projet: chemin("CDProjet"), python: chemin("CDPython"), bruts: chemin("CDBruts"), aTraiter: chemin("CDATraiter"),
            transcripts: chemin("CDTranscripts"), resumes: chemin("CDResumes"), archives: chemin("CDArchives"), cache: chemin("CDCache"),
            journaux: chemin("CDJournaux"), progression: chemin("CDProgression"), propositions: chemin("CDPropositions"),
            candidat: info["CDCandidat"] as? String ?? "",
            corbeille: chemin("CDCorbeille"), dureeCorbeille: info["CDDureeCorbeille"] as? Int ?? 30,
            prompts: chemin("CDPrompts"), profil: chemin("CDProfil"), promptsDefaut: info["CDPromptsDefaut"] as? [String: String] ?? [:])
    }
}

// MARK: - Détection : quelles autres apps utilisent le micro ?

enum DetecteurMicro {
    /// Apps (identifiants) qui captent le micro en ce moment, hors processus système et hors cette app.
    static func appsQuiEcoutent() -> Set<String> {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var taille: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &adresse, 0, nil, &taille) == noErr else { return [] }
        var objets = [AudioObjectID](repeating: 0, count: Int(taille) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &adresse, 0, nil, &taille, &objets) == noErr else { return [] }

        var apps = Set<String>()
        let moi = ProcessInfo.processInfo.processIdentifier
        for objet in objets {
            guard entier(objet, kAudioProcessPropertyIsRunningInput) == 1,
                  entier(objet, kAudioProcessPropertyPID) != UInt32(bitPattern: moi),
                  let identifiant = identifiant(objet) else { continue }
            // Services système (Siri, dictée, enregistrement d'écran…) ignorés,
            // sauf FaceTime et Safari (qui capte le micro via ses processus WebKit)
            if identifiant.hasPrefix("com.apple.") && !appleAutorisee(identifiant) { continue }
            if identifiant == Bundle.main.bundleIdentifier { continue }
            apps.insert(identifiant)
        }
        return apps
    }

    private static func appleAutorisee(_ identifiant: String) -> Bool {
        ["com.apple.FaceTime", "com.apple.Safari", "com.apple.WebKit."].contains { identifiant.hasPrefix($0) }
    }

    private static func entier(_ objet: AudioObjectID, _ selecteur: AudioObjectPropertySelector) -> UInt32? {
        var adresse = AudioObjectPropertyAddress(mSelector: selecteur, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var valeur: UInt32 = 0
        var taille = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objet, &adresse, 0, nil, &taille, &valeur) == noErr ? valeur : nil
    }

    private static func identifiant(_ objet: AudioObjectID) -> String? {
        var adresse = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var valeur: Unmanaged<CFString>?
        var taille = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objet, &adresse, 0, nil, &taille, &valeur) == noErr,
              let texte = valeur?.takeRetainedValue() as String?, !texte.isEmpty else { return nil }
        return texte
    }

    /// Nom lisible d'une app à partir de son identifiant ("us.zoom.xos" -> "zoom.us").
    static func nom(_ identifiant: String) -> String {
        if identifiant.hasPrefix("com.apple.WebKit.") { return "Safari" }
        // Les navigateurs captent le micro depuis un sous-processus : "com.google.Chrome.helper" -> Chrome
        let racine = identifiant.components(separatedBy: ".helper").first ?? identifiant
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: racine) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return identifiant
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let reglages = Reglages.lire()
    var item: NSStatusItem!
    let menu = NSMenu()

    var capture: Capture?
    var debutEnregistrement: Date?
    var appelVuPendantEnregistrement = false
    var minuterie: Timer?

    // Détection
    var micUtiliseDepuis: Date?
    var micLibreDepuis: Date?
    var dejaProposePourCetAppel = false
    let delaiAvantProposition: TimeInterval = 4   // ignore les usages très courts du micro
    let delaiAvantArretAuto: TimeInterval = 60    // l'appel est considéré fini après 1 min sans micro

    // Transcription
    var transcription: Process?
    var relancerApresTranscription = false

    // Fenêtre principale
    lazy var historique: Historique = {
        let historique = Historique(reglages: reglages)
        historique.finResume = { [weak self] nom, reussi in
            if reussi {
                self?.notifier(titre: "Résumé prêt", texte: Historique.joli(nom), categorie: "TRANSCRIPT")
            } else {
                self?.notifier(titre: "Échec du résumé", texte: "Détails dans le journal (menu > Voir le dernier journal).", categorie: "JOURNAL")
            }
        }
        return historique
    }()
    lazy var prompts = Prompts(reglages: reglages)
    var fenetre: NSWindow?
    var fenetrePrompts: NSWindow?

    var detectionActive: Bool {
        get { UserDefaults.standard.object(forKey: "detection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "detection") }
    }

    /// Lancement automatique à l'ouverture de session : l'app reste discrète dans la barre des menus.
    var lanceeALaConnexion = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let evenement = NSAppleEventManager.shared().currentAppleEvent
        lanceeALaConnexion = evenement?.eventID == kAEOpenApplication
            && evenement?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        menu.delegate = self  // menu reconstruit à chaque ouverture : l'avancement affiché est à jour
        rafraichir()
        installerMenuEdition()

        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let enregistrer = UNNotificationAction(identifier: "ENREGISTRER", title: "Enregistrer", options: [])
        let appel = UNNotificationCategory(identifier: "APPEL", actions: [enregistrer], intentIdentifiers: [], options: [])
        centre.setNotificationCategories([appel])

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.surveillerMicro() }
        // Un enregistrement resté en attente (app quittée pendant une transcription…) est repris
        if enregistrementsEnAttente() { lancerTranscription() }

        historique.viderCorbeille()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.historique.viderCorbeille() }

        // Ouverte depuis le Finder, le Dock ou Spotlight : on montre la fenêtre
        if !lanceeALaConnexion { ouvrirFenetre() }
    }

    /// Sans barre des menus (app de la barre des menus seulement), ⌘C, ⌘V, ⌘X, ⌘A et ⌘Z ne font rien :
    /// macOS les fait passer par le menu Édition. Ce menu, jamais affiché, les rend aux champs de texte.
    func installerMenuEdition() {
        let principal = NSMenu()
        let edition = NSMenu(title: "Édition")
        edition.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let retablir = edition.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        retablir.keyEquivalentModifierMask = [.command, .shift]
        edition.addItem(.separator())
        edition.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edition.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edition.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edition.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let element = NSMenuItem(title: "Édition", action: nil, keyEquivalent: "")
        element.submenu = edition
        principal.addItem(element)
        // ⌘W ferme la fenêtre au premier plan
        let fenetre = NSMenu(title: "Fenêtre")
        fenetre.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let elementFenetre = NSMenuItem(title: "Fenêtre", action: nil, keyEquivalent: "")
        elementFenetre.submenu = fenetre
        principal.addItem(elementFenetre)
        NSApp.mainMenu = principal
    }

    /// Double-clic sur l'app dans le Finder alors qu'elle tourne déjà
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ouvrirFenetre()
        return true
    }

    // MARK: Menu et icône

    func rafraichir() {
        let symbole: String
        if capture != nil {
            symbole = "record.circle.fill"
            let duree = Int(Date().timeIntervalSince(debutEnregistrement ?? Date()))
            item.button?.title = String(format: " %d:%02d", duree / 60, duree % 60)
        } else {
            symbole = transcription != nil ? "waveform" : "mic"
            item.button?.title = ""
        }
        let image = NSImage(systemSymbolName: symbole, accessibilityDescription: "Calls Debrief")
        if capture != nil {
            item.button?.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            image?.isTemplate = true
            item.button?.image = image
        }

        menu.removeAllItems()
        let etat: String
        if capture != nil {
            etat = "Enregistrement en cours"
        } else if transcription != nil {
            if let p = historique.lireProgression() {
                etat = "Transcription : \(p.etape)" + (p.fraction.map { " (\(Int($0 * 100)) %)" } ?? "…")
            } else {
                etat = "Transcription en cours…"
            }
        } else {
            etat = "Prêt"
        }
        menu.addItem(withTitle: etat, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ouvrir Calls Debrief", action: #selector(ouvrirFenetre), keyEquivalent: "o").target = self
        if capture != nil {
            menu.addItem(withTitle: "Arrêter et transcrire", action: #selector(arreterEnregistrement), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Enregistrer", action: #selector(demarrerEnregistrement), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Ouvrir le dossier des transcripts", action: #selector(ouvrirTranscripts), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Ouvrir la corbeille", action: #selector(ouvrirCorbeille), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Prompts et profil des résumés…", action: #selector(ouvrirPrompts), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Voir le dernier journal", action: #selector(ouvrirJournal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let detection = menu.addItem(withTitle: "Proposer d'enregistrer les appels", action: #selector(basculerDetection), keyEquivalent: "")
        detection.target = self
        detection.state = detectionActive ? .on : .off
        let demarrage = menu.addItem(withTitle: "Lancer au démarrage du Mac", action: #selector(basculerDemarrage), keyEquivalent: "")
        demarrage.target = self
        demarrage.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(quitter), keyEquivalent: "q").target = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rafraichir() }

    // MARK: Détection des appels

    func surveillerMicro() {
        let apps = DetecteurMicro.appsQuiEcoutent()
        let maintenant = Date()

        if apps.isEmpty {
            micUtiliseDepuis = nil
            dejaProposePourCetAppel = false
            if micLibreDepuis == nil { micLibreDepuis = maintenant }
        } else {
            micLibreDepuis = nil
            if micUtiliseDepuis == nil { micUtiliseDepuis = maintenant }
        }

        if capture != nil {
            if !apps.isEmpty { appelVuPendantEnregistrement = true }
            // Arrêt automatique seulement si un appel a été vu : un enregistrement lancé à la main sans appel continue
            if appelVuPendantEnregistrement, let libre = micLibreDepuis, maintenant.timeIntervalSince(libre) >= delaiAvantArretAuto {
                arreterEnregistrement()
            }
        } else if detectionActive, !dejaProposePourCetAppel,
                  let depuis = micUtiliseDepuis, maintenant.timeIntervalSince(depuis) >= delaiAvantProposition {
            dejaProposePourCetAppel = true
            let noms = apps.map(DetecteurMicro.nom).sorted().joined(separator: ", ")
            notifier(titre: "Appel détecté (\(noms))", texte: "Enregistrer ? Pense à prévenir ton interlocuteur.", categorie: "APPEL")
        }
    }

    // MARK: Enregistrement

    @objc func demarrerEnregistrement() {
        guard capture == nil else { return }
        let horodatage = DateFormatter()
        horodatage.dateFormat = "yyyy-MM-dd_HH'h'mm"
        var dossier = reglages.bruts.appendingPathComponent(horodatage.string(from: Date()))
        var n = 2
        while FileManager.default.fileExists(atPath: dossier.path) {
            dossier = reglages.bruts.appendingPathComponent("\(horodatage.string(from: Date()))_\(n)")
            n += 1
        }
        let capture = Capture(dossier: dossier)
        capture.surInterruption = { [weak self] _ in
            DispatchQueue.main.async { self?.finEnregistrement(interrompu: true) }
        }
        self.capture = capture
        debutEnregistrement = Date()
        appelVuPendantEnregistrement = !DetecteurMicro.appsQuiEcoutent().isEmpty
        rafraichir()

        Task { @MainActor in
            do {
                try await capture.demarrer()
                self.minuterie = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.rafraichir() }
            } catch {
                self.capture = nil
                try? FileManager.default.removeItem(at: dossier)
                self.rafraichir()
                self.notifier(titre: "Enregistrement impossible", texte: error.localizedDescription)
            }
        }
    }

    @objc func arreterEnregistrement() {
        guard let capture else { return }
        Task { @MainActor in
            await capture.arreter()
            self.finEnregistrement(interrompu: false)
        }
    }

    func finEnregistrement(interrompu: Bool) {
        guard capture != nil else { return }
        capture = nil
        minuterie?.invalidate()
        minuterie = nil
        rafraichir()
        if interrompu {
            notifier(titre: "Enregistrement interrompu par macOS", texte: "Ce qui a été enregistré va quand même être transcrit.")
        }
        lancerTranscription()
    }

    // MARK: Transcription

    func enregistrementsEnAttente() -> Bool {
        let dossiers = (try? FileManager.default.contentsOfDirectory(atPath: reglages.bruts.path)) ?? []
        return dossiers.contains { FileManager.default.fileExists(atPath: reglages.bruts.appendingPathComponent($0).appendingPathComponent("debuts.json").path) }
    }

    func lancerTranscription() {
        guard transcription == nil else {
            relancerApresTranscription = true  // le prochain passage prendra le nouvel enregistrement
            return
        }
        try? FileManager.default.createDirectory(at: reglages.journaux, withIntermediateDirectories: true)
        let horodatage = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let journal = reglages.journaux.appendingPathComponent("\(horodatage).log")
        FileManager.default.createFile(atPath: journal.path, contents: nil)

        try? FileManager.default.removeItem(at: reglages.progression)  // reste d'une transcription interrompue
        let process = Process()
        process.executableURL = reglages.python
        process.arguments = ["-m", "calls_debrief.apres_enregistrement"]
        process.currentDirectoryURL = reglages.projet
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        if let sortie = try? FileHandle(forWritingTo: journal) {
            process.standardOutput = sortie
            process.standardError = sortie
        }
        process.terminationHandler = { [weak self] fini in
            DispatchQueue.main.async { self?.finTranscription(code: fini.terminationStatus) }
        }
        do {
            try process.run()
            transcription = process
            historique.transcriptionEnCours = true
            historique.recharger()
        } catch {
            notifier(titre: "Transcription impossible", texte: error.localizedDescription)
        }
        rafraichir()
    }

    func finTranscription(code: Int32) {
        transcription = nil
        try? FileManager.default.removeItem(at: reglages.progression)
        historique.transcriptionEnCours = false
        historique.recharger()
        if code == 0 {
            notifier(titre: "Transcription terminée", texte: "Clique pour lire le transcript.", categorie: "TRANSCRIPT")
        } else {
            notifier(titre: "Échec de la transcription", texte: "Détails dans le journal (menu > Voir le dernier journal).", categorie: "JOURNAL")
        }
        if relancerApresTranscription {
            relancerApresTranscription = false
            lancerTranscription()
        }
        rafraichir()
    }

    // MARK: Actions du menu

    @objc func ouvrirFenetre() {
        if fenetre == nil {
            let vue = FenetrePrincipale(historique: historique, prompts: prompts,
                                        surImport: { [weak self] in self?.lancerTranscription() },
                                        ouvrirJournal: { [weak self] in self?.ouvrirJournal() },
                                        ouvrirPrompts: { [weak self] in self?.ouvrirPrompts() })
            let fenetre = NSWindow(contentViewController: NSHostingController(rootView: vue))
            fenetre.title = "Calls Debrief"
            fenetre.setContentSize(NSSize(width: 900, height: 600))
            fenetre.isReleasedWhenClosed = false
            fenetre.center()
            fenetre.setFrameAutosaveName("FenetrePrincipale")
            self.fenetre = fenetre
        }
        historique.recharger()
        NSApp.activate(ignoringOtherApps: true)
        fenetre?.makeKeyAndOrderFront(nil)
    }

    @objc func ouvrirPrompts() {
        if fenetrePrompts == nil {
            let fenetre = NSWindow(contentViewController: NSHostingController(rootView: FenetrePrompts(prompts: prompts)))
            fenetre.title = "Prompts et profil"
            fenetre.setContentSize(NSSize(width: 720, height: 460))
            fenetre.isReleasedWhenClosed = false
            fenetre.center()
            fenetre.setFrameAutosaveName("FenetrePrompts")
            fenetrePrompts = fenetre
        }
        prompts.recharger()
        NSApp.activate(ignoringOtherApps: true)
        fenetrePrompts?.makeKeyAndOrderFront(nil)
    }

    @objc func ouvrirTranscripts() {
        try? FileManager.default.createDirectory(at: reglages.transcripts, withIntermediateDirectories: true)
        NSWorkspace.shared.open(reglages.transcripts)
    }

    @objc func ouvrirCorbeille() {
        try? FileManager.default.createDirectory(at: reglages.corbeille, withIntermediateDirectories: true)
        NSWorkspace.shared.open(reglages.corbeille)
    }

    @objc func ouvrirJournal() {
        let journaux = ((try? FileManager.default.contentsOfDirectory(atPath: reglages.journaux.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        if let dernier = journaux.last {
            NSWorkspace.shared.open(reglages.journaux.appendingPathComponent(dernier))
        } else {
            notifier(titre: "Aucun journal", texte: "Aucune transcription n'a encore été lancée depuis l'app.")
        }
    }

    @objc func basculerDetection() {
        detectionActive.toggle()
        rafraichir()
    }

    @objc func basculerDemarrage() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notifier(titre: "Réglage impossible", texte: error.localizedDescription)
        }
        rafraichir()
    }

    @objc func quitter() {
        guard let capture else { NSApp.terminate(nil); return }
        Task { @MainActor in
            await capture.arreter()  // les pistes restent dans .etat/enregistrements et seront transcrites au prochain lancement
            NSApp.terminate(nil)
        }
    }

    // MARK: Notifications

    func notifier(titre: String, texte: String, categorie: String = "") {
        let contenu = UNMutableNotificationContent()
        contenu.title = titre
        contenu.body = texte
        contenu.categoryIdentifier = categorie
        contenu.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: contenu, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let categorie = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch categorie {
            case "APPEL" where action == "ENREGISTRER" || action == UNNotificationDefaultActionIdentifier:
                self.demarrerEnregistrement()
            case "TRANSCRIPT":
                self.ouvrirFenetre()
            case "JOURNAL":
                self.ouvrirJournal()
            default:
                break
            }
        }
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // pas d'icône dans le Dock
app.run()
