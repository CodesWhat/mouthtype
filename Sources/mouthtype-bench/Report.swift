import Foundation

enum Report {
    static func aggregate(_ engine: inout EngineReport) {
        guard let clips = engine.warm?.clips, !clips.isEmpty else { return }
        let short = clips.filter { $0.audioSeconds <= 10 }
        engine.shortClipMedianMs = short.isEmpty ? nil : Stats.median(short.map(\.medianMs))
        let processing = clips.reduce(0) { $0 + $1.medianMs / 1000 }
        let audio = clips.reduce(0) { $0 + $1.audioSeconds }
        engine.overallRTFx = processing > 0 ? audio / processing : nil
        engine.werSynthetic = wer(clips, .synthetic)
        engine.werReal = wer(clips, .real)
        engine.werCustom = wer(clips, .custom)
    }

    private static func wer(_ clips: [ClipResult], _ set: ClipSet) -> Double? {
        let subset = clips.filter { $0.set == set }
        let words = subset.reduce(0) { $0 + $1.referenceWords }
        guard words > 0 else { return nil }
        return Double(subset.reduce(0) { $0 + $1.edits }) / Double(words)
    }

    static func markdown(_ report: BenchReport) -> String {
        var out = "# Mouthtype engine benchmark\n\n"
        let m = report.machine
        let versions = m.packageVersions
        out += "Machine: \(m.chip), \(m.ramGB) GB, macOS \(m.macOS), \(m.swift). "
        out += "FluidAudio \(versions["fluidaudio"] ?? "?"), WhisperKit \(versions["whisperkit"] ?? "?").\n\n"
        out += "Date: \(report.date). Corpus: `\(report.corpus)`. \(report.runsPerClip) timed runs per clip after \(report.warmupRuns) untimed warm-up.\n\n"
        if !report.hasRealSpeech {
            out += "> **WARNING: no real human speech in this corpus.** The WER columns come from TTS audio only, which flatters accuracy. Do not pick an engine on them.\n\n"
        }

        out += "## Summary\n\n"
        out +=
            "| Engine | Cold prepare (s) | Warm load (s) | First transcribe (ms) | Short-clip median (ms) | Overall RTFx | WER synthetic | WER real | Peak RSS (MB) | Peak footprint (MB) | Model size (MB) | Status |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for e in report.engines {
            out +=
                "| \(e.displayName) (`\(e.engineID)`) | \(coldCell(e)) | \(warmCell(e)) | \(num(e.warm?.firstTranscribeMs, 0)) | \(num(e.shortClipMedianMs, 0)) | \(num(e.overallRTFx, 1)) | \(pct(e.werSynthetic)) | \(pct(e.werReal)) | \(mb(e.warm?.peakRSSBytes)) | \(mb(e.warm?.peakFootprintBytes)) | \(mb(e.warm?.modelBytes ?? e.cold?.modelBytes)) | \(e.error == nil ? "ok" : "FAILED") |\n"
        }
        out += "\nCold prepare is the first process for the engine: download plus load, with CoreML compile folded into load. "
        out += "Warm load is `prepare()` in a fresh process with the models already on disk. "
        out +=
            "First transcribe is the first untimed transcription in the warm process, which absorbs any lazy CoreML specialization that `prepare()` did not. Short-clip median is the median of per-clip medians for clips of 10 s or less. "
        out += "Overall RTFx is total audio seconds over the summed per-clip median processing seconds. "
        out += "WER is corpus-level (total edits over total reference words) on the last timed run of each clip. "
        out +=
            "Peak RSS is the warm process after loading and transcribing the whole corpus. Peak footprint is the same process's peak `phys_footprint` from `TASK_VM_INFO`, which also counts GPU-backed unified memory.\n\n"
        if report.engines.contains(where: { $0.cold?.prepare?.downloaded == false }) {
            out += "Engines marked `(models already on disk)` in the cold column had their files cached before this run, so their cold number is not a first-ever download.\n\n"
        }

        let failures = report.engines.filter { $0.error != nil }
        if !failures.isEmpty {
            out += "## Failures\n\n"
            for e in failures { out += "- `\(e.engineID)`: \(e.error ?? "")\n" }
            out += "\n"
        }

        out += "## Per-clip results\n\n"
        for e in report.engines {
            guard let clips = e.warm?.clips, !clips.isEmpty else { continue }
            out += "### \(e.displayName)\n\n"
            out += "| Clip | Set | Audio (s) | Median (ms) | p95 (ms) | RTFx | WER |\n|---|---|---|---|---|---|---|\n"
            for c in clips {
                let clipWER = c.referenceWords > 0 ? Double(c.edits) / Double(c.referenceWords) : nil
                out += "| \(c.name) | \(c.set.rawValue) | \(num(c.audioSeconds, 1)) | \(num(c.medianMs, 0)) | \(num(c.p95Ms, 0)) | \(num(c.rtfx, 1)) | \(pct(clipWER)) |\n"
            }
            out += "\n"
        }

        out += "## Transcripts\n\n"
        for e in report.engines {
            guard let clips = e.warm?.clips, !clips.isEmpty else { continue }
            out += "### \(e.displayName)\n\n"
            for c in sample(clips) {
                out += "`\(c.name)`\n\n- Reference: \(c.reference)\n- Hypothesis: \(c.hypothesis)\n\n"
            }
        }
        return out
    }

    private static func sample(_ clips: [ClipResult]) -> [ClipResult] {
        let synthetic = clips.first { $0.set == .synthetic && $0.audioSeconds > 5 }
        let real = clips.filter { $0.set == .real }.prefix(2)
        let custom = clips.filter { $0.set == .custom }.prefix(2)
        return ([synthetic].compactMap { $0 }) + Array(real) + Array(custom)
    }

    private static func coldCell(_ e: EngineReport) -> String {
        guard let p = e.cold?.prepare else { return "n/a" }
        let total = p.downloadSeconds + p.loadSeconds
        if !p.downloaded {
            return "\(num(total, 1)) (models already on disk)"
        }
        return "\(num(total, 1)) (download \(num(p.downloadSeconds, 1)) + load \(num(p.loadSeconds, 1)))"
    }

    private static func warmCell(_ e: EngineReport) -> String {
        guard let p = e.warm?.prepare else { return "n/a" }
        return num(p.downloadSeconds + p.loadSeconds, 1)
    }

    private static func num(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    private static func pct(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func mb(_ bytes: Int?) -> String {
        guard let bytes else { return "n/a" }
        return String(format: "%.0f", Double(bytes) / 1_048_576)
    }
}
