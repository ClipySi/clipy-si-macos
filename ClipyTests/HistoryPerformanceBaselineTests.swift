//
//  HistoryPerformanceBaselineTests.swift
//  ClipyTests
//
//  M-UI.11 P0: per-stage timing of the panel's history pipeline over the synthetic encrypted
//  corpora (PerformanceFixture) — DB fetch → AES-GCM decrypt → 2-pass redaction evaluate →
//  code classification → the production ClipDisplayBuilder pipeline. Prints one machine-readable
//  `perf-baseline …` line per (size, stage) with durations and counts ONLY — never titles, search
//  text, or IDs (plan v2 §3.2). Assertions cover correctness (tombstone exclusion, zero decrypt
//  failures); they never assert timing — thresholds live in the plan's §7 table and are judged on
//  Release measurements, not the CI machine.
//
//  Sizes 30/250/500/5,000 run everywhere. The 100,000-row corpus is opt-in:
//      TEST_RUNNER_CLIPY_PERF_XL=1 xcodebuild … test   (xcodebuild forwards TEST_RUNNER_-prefixed
//      variables into the test runner's environment as CLIPY_PERF_XL).
//
//  Protocol: authoritative numbers come from a Release `-only-testing:` run of THIS suite alone
//  (contention-free; §2 of the baseline report has the exact command) — full-suite gate runs are
//  Debug and share the machine with 40+ concurrent suites, so their timings are indicative only.
//  A warm-up pass absorbs one-time lazy initialization (the redaction core's detector setup) so
//  samples measure steady-state stage cost; with ≤7 samples the summary reports p50/min/max — no
//  p95 pretence from a sample count that small.
//

import ClipySiCore
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite(.serialized) struct HistoryPerformanceBaselineTests {
    static var sizes: [Int] {
        let base = [30, 250, 500, 5_000]
        let wantsXL = ProcessInfo.processInfo.environment["CLIPY_PERF_XL"] == "1"
        return wantsXL ? base + [100_000] : base
    }

    /// Mirrors `MaskingService.live`'s per-title work — the SAME 2-pass shape (`isSecret` then
    /// `mask`, each running the detector when enabled) with mask ON / full style — but reads no
    /// AppSettings/UserDefaults, so the measured cost is the core's, not settings I/O.
    private static func liveShapedConfig() -> MaskConfig {
        var config = defaultConfig()
        config.enabled = true
        config.style = .full
        return config
    }

    @Test(arguments: sizes)
    func stageBaseline(size: Int) throws {
        let clock = ContinuousClock()
        var corpus: Corpus?
        let buildTime = try clock.measure { corpus = try PerfFixture.makeCorpus(liveCount: size) }
        guard let corpus else { return }
        let iterations = size >= 100_000 ? 3 : (size >= 5_000 ? 5 : 7)
        let config = Self.liveShapedConfig()

        // Warm-up: touch the detector and classifier once so their one-time lazy setup lands
        // outside the samples (it showed as a 2.5 ms outlier on the very first mask interval).
        _ = isSecret(text: "warm-up probe", config: config)
        _ = mask(text: "warm-up probe", config: config)
        _ = CodeClassifier.classify("{\"warm\": true, \"up\": 1}")

        // Corpus self-validation: the tombstone-exclusion assertions below prove nothing unless
        // tombstones actually exist in the DB alongside the live rows.
        let deadInDB = try corpus.database.read { db in
            try Clip.where { $0.deletedAt.isNot(nil) }.fetchCount(db)
        }
        #expect(corpus.tombstoneCount == size / 10)
        #expect(deadInDB == corpus.tombstoneCount)

        var fetchSamples: [Duration] = []
        var decryptSamples: [Duration] = []
        var maskSamples: [Duration] = []
        var classifySamples: [Duration] = []
        var pipelineSamples: [Duration] = []
        var secretCount = 0
        var codeCount = 0

        try withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = MaskingService { text in
                guard !text.isEmpty else { return MaskingResult(isSecret: false, display: text) }
                let secret = isSecret(text: text, config: config)
                let display = mask(text: text, config: config)
                return MaskingResult(isSecret: secret, display: display)
            }
        } operation: {
            let repository = ClipRepository()
            let builder = ClipDisplayBuilder()
            let cipher = PerfFixture.cipher

            for iteration in 0..<iterations {
                // Stage 1 — the panel's history SELECT (newest-first, full display limit).
                var fetched: [Clip] = []
                fetchSamples.append(try clock.measure {
                    fetched = try repository.recentClips(limit: size)
                })

                // Stage 2 — AES-GCM open of every fetched title.
                var titles: [String] = []
                titles.reserveCapacity(fetched.count)
                decryptSamples.append(try clock.measure {
                    for clip in fetched {
                        if let title = String(bytes: try cipher.open(clip.titleCipher), encoding: .utf8) {
                            titles.append(title)
                        }
                    }
                })

                // Stage 3 — redaction evaluate, 2-pass exactly like MaskingService.live (mask ON).
                var displays: [String] = []
                displays.reserveCapacity(titles.count)
                var secrets = 0
                maskSamples.append(clock.measure {
                    for title in titles {
                        if isSecret(text: title, config: config) { secrets += 1 }
                        displays.append(mask(text: title, config: config))
                    }
                })

                // Stage 4 — code classification over the display strings (the panel-row pass).
                var code = 0
                classifySamples.append(clock.measure {
                    for display in displays where CodeClassifier.classify(display) != nil {
                        code += 1
                    }
                })

                // Stage 5 — the production display build (fetch result → ClipDisplay), i.e. what
                // MenuModel.history() runs per open: decrypt + evaluate per row via the builder.
                var built: [ClipDisplay] = []
                pipelineSamples.append(clock.measure {
                    built = fetched.map(builder.display(of:))
                })

                if iteration == 0 {
                    secretCount = secrets
                    codeCount = code
                    // Correctness gates — a fixture or filter regression invalidates every number.
                    // Deliberately count-shaped: a failure message must carry only integers, never
                    // a [Clip]/[ClipDisplay] value dump (§3.2 forbids IDs/bundle ids/titles in
                    // test output on ANY toolchain's #expect rendering).
                    let ghostRows = fetched.count { $0.deletedAt != nil }
                    let undecryptable = built.count { $0.decryptFailed }
                    #expect(fetched.count == corpus.liveCount)
                    #expect(ghostRows == 0, "tombstones must not reach the display pipeline")
                    #expect(titles.count == fetched.count)
                    #expect(undecryptable == 0, "every live fixture title must decrypt")
                    #expect(secrets > 0, "the corpus must exercise the secret detector")
                    #expect(code > 0, "the corpus must exercise the code classifier")
                }
            }
        }

        report("corpusBuild", size: size, rows: corpus.liveCount + corpus.tombstoneCount, [buildTime])
        report("dbFetch", size: size, rows: corpus.liveCount, fetchSamples)
        report("decrypt", size: size, rows: corpus.liveCount, decryptSamples)
        report("maskEvaluate2pass", size: size, rows: corpus.liveCount, maskSamples, extra: "secrets=\(secretCount)")
        report("classify", size: size, rows: corpus.liveCount, classifySamples, extra: "code=\(codeCount)")
        report("displayBuild", size: size, rows: corpus.liveCount, pipelineSamples)
    }

    /// The 2-pass evaluate cost per mask style (plan §8.5 wants full/prefix2/suffix4/off covered):
    /// same 500-row corpus titles, one summary line per style. `off` short-circuits the detector in
    /// `mask` but not `isSecret`, so it is NOT free — that asymmetry is exactly what P1-R's
    /// one-pass API targets.
    @Test func maskStyleBaseline() throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 500)
        let clock = ContinuousClock()
        let cipher = PerfFixture.cipher

        var titles: [String] = []
        try withDependencies {
            $0.defaultDatabase = corpus.database
        } operation: {
            for clip in try ClipRepository().recentClips(limit: 500) {
                if let title = String(bytes: try cipher.open(clip.titleCipher), encoding: .utf8) {
                    titles.append(title)
                }
            }
        }
        #expect(titles.count == corpus.liveCount)

        struct StyleCase {
            let label: String
            let style: MaskStyle
            let enabled: Bool
        }
        let styles = [
            StyleCase(label: "full", style: .full, enabled: true),
            StyleCase(label: "prefix2", style: .prefix2, enabled: true),
            StyleCase(label: "suffix4", style: .suffix4, enabled: true),
            StyleCase(label: "off", style: .full, enabled: false)
        ]
        for styleCase in styles {
            var config = defaultConfig()
            config.enabled = styleCase.enabled
            config.style = styleCase.style
            _ = isSecret(text: "warm-up probe", config: config)
            var samples: [Duration] = []
            var secrets = 0
            for _ in 0..<7 {
                secrets = 0
                samples.append(clock.measure {
                    for title in titles {
                        if isSecret(text: title, config: config) { secrets += 1 }
                        _ = mask(text: title, config: config)
                    }
                })
            }
            report("maskStyle_\(styleCase.label)", size: 500, rows: titles.count, samples, extra: "secrets=\(secrets)")
        }
    }

    /// M-UI.11 P1: the model-level open commit. `reset()` rebuilds the stored snapshot once and
    /// classifies ONLY the visible page through PanelClassificationCache — where the P0 pipeline
    /// classified every row up front (~220 µs/row). The first iteration is the cold-cache cost
    /// (visible in max); later iterations are the warm re-open. The one-shot `chipsExactCounts`
    /// line prices the deferred full classification that opening the filter bar triggers.
    @MainActor @Test func modelResetBaseline() throws {
        let clock = ContinuousClock()
        for size in [500, 5_000] {
            var rng = SeededGenerator(seed: 0xC11B_0A5E)
            let rows = (0..<size).map { index in
                var row = PanelRow.clip(UUID(), title: PerfFixture.title(at: index, using: &rng))
                row.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
                row.needsCodeClassification = true
                return row
            }
            let model = HistoryPanelModel()
            model.itemsPerPage = 10
            var resetSamples: [Duration] = []
            for _ in 0..<7 {
                resetSamples.append(clock.measure {
                    model.reset(historyRows: rows, snippetRows: [])
                })
            }
            report("modelResetLazyClassify", size: size, rows: size, resetSamples)

            let chipsTime = clock.measure { model.isFilterBarOpen = true }
            report("chipsExactCounts", size: size, rows: size, [chipsTime])
            #expect(model.visibleRows.count == 10)
            #expect(model.categoryCounts[.all] == size)
        }
    }

    /// M-UI.11 P2: the read-service open path — what a cold open costs OFF the MainActor now.
    /// `serviceOpenPage` fetches + decrypts one page (pageSize + sentinel) regardless of corpus
    /// size — the exit criterion made measurable; `serviceFullWindow` is the search-hydration
    /// interim (≈ the pre-P2 whole-window open cost, now paid only when the user narrows).
    /// Mask ON / full style via the same live-shaped evaluator as `stageBaseline`.
    @Test func serviceOpenPageBaseline() async throws {
        let clock = ContinuousClock()
        let config = Self.liveShapedConfig()
        _ = isSecret(text: "warm-up probe", config: config)
        for size in Self.sizes {
            let corpus = try PerfFixture.makeCorpus(liveCount: size)
            try await withDependencies {
                $0.defaultDatabase = corpus.database
                $0.historyCipher = PerfFixture.cipher
                $0.maskingService = MaskingService { text in
                    guard !text.isEmpty else { return MaskingResult(isSecret: false, display: text) }
                    return MaskingResult(isSecret: isSecret(text: text, config: config),
                                         display: mask(text: text, config: config))
                }
            } operation: {
                let service = HistoryReadService()
                let request = HistoryReadService.PageRequest(
                    pageSize: 10, historyLimit: 100_000, ascending: false,
                    policy: DisplayPolicy(maskEnabled: true, maskStyleRaw: "full",
                                          classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
                var openSamples: [Duration] = []
                var pageRows = 0
                for _ in 0..<7 {
                    var result: HistoryReadService.PageResult?
                    openSamples.append(await clock.measure {
                        result = await service.openPage(request)
                    })
                    pageRows = result?.rows.count ?? 0
                }
                #expect(pageRows == 10)
                var windowSamples: [Duration] = []
                var windowRows = 0
                for _ in 0..<(size >= 5_000 ? 3 : 5) {
                    windowSamples.append(await clock.measure {
                        windowRows = await service.fullWindow(request).rows.count
                    })
                }
                #expect(windowRows == corpus.liveCount)
                report("serviceOpenPage", size: size, rows: pageRows, openSamples)
                report("serviceFullWindow", size: size, rows: windowRows, windowSamples)
            }
        }
    }

    /// One summary line per stage: counts and milliseconds only (§3.2 non-leak contract).
    /// p50/min/max — with ≤7 samples a p95 would just be the max wearing a lab coat.
    private func report(_ stage: String, size: Int, rows: Int, _ samples: [Duration], extra: String = "") {
        let sorted = samples.map(milliseconds(of:)).sorted()
        guard !sorted.isEmpty else { return }
        let line = String(
            format: "perf-baseline size=%d stage=%@ rows=%d iters=%d p50_ms=%.2f min_ms=%.2f max_ms=%.2f %@",
            size, stage, rows, sorted.count, sorted[sorted.count / 2], sorted[0], sorted[sorted.count - 1], extra)
        print(line.trimmingCharacters(in: .whitespaces))
    }

    private func milliseconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private typealias Corpus = PerfFixture.Corpus
