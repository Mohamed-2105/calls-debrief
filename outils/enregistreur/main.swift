// Outil en ligne de commande (python enregistrer.py) : capture jusqu'à Ctrl+C, SIGTERM ou fermeture du terminal.
// Usage : enregistreur <dossier_sortie>

import Foundation

guard CommandLine.arguments.count == 2 else {
    journal("Usage : enregistreur <dossier_sortie>")
    exit(1)
}
let capture = Capture(dossier: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
capture.surInterruption = { _ in exit(1) }

// Ctrl+C, SIGTERM ou fermeture de la fenêtre (SIGHUP) : arrêt propre, pour que les fichiers soient lisibles
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Task {
            await capture.arreter()
            exit(0)
        }
    }
    source.resume()
    sources.append(source)
}

Task {
    do {
        try await capture.demarrer()
        print("PRET")
        fflush(stdout)
    } catch {
        journal(error.localizedDescription)
        exit(2)
    }
}
dispatchMain()
