// Moteur de capture partagé par l'outil en ligne de commande et l'app de la barre des menus.
// Enregistre en même temps le son de l'ordi (les autres participants) et le micro (toi),
// chacun dans son fichier, via ScreenCaptureKit (macOS 15+).
// Produit dans le dossier : systeme.m4a, micro.m4a et debuts.json (premier son de chaque piste, pour les aligner).
// debuts.json est écrit en dernier : sa présence signifie que l'enregistrement est complet.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum ErreurCapture: LocalizedError {
    case permissionEcran
    case aucunEcran
    case demarrage(Error)

    var errorDescription: String? {
        switch self {
        case .permissionEcran:
            return "Accès refusé à l'enregistrement de l'audio système. Réglages Système > Confidentialité et sécurité > "
                + "Enregistrement de l'écran et de l'audio système : autorise l'app (ou ton terminal), puis relance-la."
        case .aucunEcran:
            return "Aucun écran trouvé."
        case .demarrage(let e):
            return "Démarrage de la capture impossible : \(e.localizedDescription) (vérifie aussi l'autorisation Microphone)."
        }
    }
}

func journal(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Écrit une piste audio en AAC ; l'écriture démarre au premier son reçu, au format de la source.
final class Piste {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var debut: CMTime?

    init(url: URL) { self.url = url }

    func ajouter(_ buffer: CMSampleBuffer) {
        guard buffer.isValid, CMSampleBufferGetNumSamples(buffer) > 0 else { return }
        if writer == nil { demarrer(avec: buffer) }
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    private func demarrer(avec buffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: min(Int(asbd.mChannelsPerFrame), 2),
                AVEncoderBitRateKey: 128_000,
            ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else {
                journal("Écriture de \(url.lastPathComponent) impossible : \(String(describing: writer.error))")
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            self.input = input
            self.debut = pts
        } catch {
            journal("Création de \(url.lastPathComponent) impossible : \(error)")
        }
    }

    func terminer() async {
        guard let writer, let input else { return }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            journal("Fichier \(url.lastPathComponent) incomplet : \(String(describing: writer.error))")
        }
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let dossier: URL
    private let systeme: Piste
    private let micro: Piste
    private let file = DispatchQueue(label: "capture.audio")
    private var stream: SCStream?
    private var arretee = false
    /// Appelé si macOS interrompt la capture (les fichiers sont alors finalisés automatiquement).
    var surInterruption: ((Error) -> Void)?

    init(dossier: URL) {
        self.dossier = dossier
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        systeme = Piste(url: dossier.appendingPathComponent("systeme.m4a"))
        micro = Piste(url: dossier.appendingPathComponent("micro.m4a"))
    }

    func demarrer() async throws {
        let contenu: SCShareableContent
        do {
            contenu = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ErreurCapture.permissionEcran
        }
        guard let ecran = contenu.displays.first else { throw ErreurCapture.aucunEcran }

        let config = SCStreamConfiguration()
        // ScreenCaptureKit exige une vidéo : on la réduit au strict minimum
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true  // micro par défaut du système

        let stream = SCStream(filter: SCContentFilter(display: ecran, excludingWindows: []), configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: file)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: file)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: file)
            try await stream.startCapture()
        } catch {
            throw ErreurCapture.demarrage(error)
        }
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: systeme.ajouter(buffer)
        case .microphone: micro.ajouter(buffer)
        default: break  // images ignorées
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        journal("Capture interrompue : \(error)")
        Task {
            await self.arreter()
            self.surInterruption?(error)
        }
    }

    /// Arrête la capture et finalise les fichiers. Sans effet si déjà arrêtée.
    func arreter() async {
        let dejaArretee = file.sync { () -> Bool in
            defer { arretee = true }
            return arretee
        }
        guard !dejaArretee else { return }
        try? await stream?.stopCapture()
        file.sync {}  // plus aucun son n'arrive : on vide la file avant de finaliser
        await systeme.terminer()
        await micro.terminer()

        var debuts: [String: Double] = [:]
        if let d = systeme.debut { debuts["systeme"] = d.seconds }
        if let d = micro.debut { debuts["micro"] = d.seconds }
        if let data = try? JSONSerialization.data(withJSONObject: debuts) {
            try? data.write(to: dossier.appendingPathComponent("debuts.json"))
        }
    }
}
