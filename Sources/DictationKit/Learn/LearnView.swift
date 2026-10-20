import AppKit
import SwiftUI

/// The Learn tile at the top of Corrections: your score and the general set's, the Learn button,
/// and, while a tune runs, the candidates racing, what changed in the prompt, and Keep/Discard.
struct LearnView: View {
    @ObservedObject var controller: LearnController
    @Environment(\.dateContext) private var dates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let good = Color(nsColor: .systemGreen)
    static let learning = [Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemOrange)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scores
            if let status = controller.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learn.status")
                    .transition(.opacity)
            }
            if let phase = controller.phase, phase != .reading, !isMeasured(phase) {
                candidates(phase)
            }
            if let result = controller.result {
                diff(result)
                resultRow(result)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : .spring(duration: 0.5), value: controller.phase)
        .animation(reduceMotion ? nil : .spring(duration: 0.5), value: controller.result)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learn.tile")
        .onTabShown { controller.measureIfNeeded() }
        .onChange(of: controller.setup.id) { controller.measureIfNeeded() }
    }

    /// One card: the two scores on a grid, the Learn button (or why it can't run) at the trailing edge.
    private var scores: some View {
        HStack(alignment: .center, spacing: 16) {
            ScoreRing(value: controller.mine, before: controller.mineBefore, up: controller.result != nil,
                      label: "Your corrections · \(controller.setup.title)", id: "learn.score.mine", deltaAsHeld: false)
                .frame(minWidth: 230, alignment: .leading)
            ScoreRing(value: controller.generalScore, before: controller.generalBefore, up: false,
                      label: "General test set · guard", id: "learn.score.general", deltaAsHeld: true)
                .frame(minWidth: 230, alignment: .leading)
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
    }

    @ViewBuilder private var action: some View {
        switch controller.gate {
        case .ready:
            LearnButton(title: "Learn", busy: false) { controller.learn() }
        case .running:
            LearnButton(title: "Learning…", busy: true) {}
        case .measuring:
            LearnButton(title: "Measuring…", busy: true) {}
        case .done:
            LearnButton(title: "Learned", busy: false, disabled: true) {}
        case .allLearned:
            VStack(alignment: .trailing, spacing: 4) {
                LearnButton(title: "Learned", busy: false, disabled: true) {}
                Text("Every correction is learned. Correct more to go on.").font(.caption).foregroundStyle(.secondary)
            }
        case .needMore(let have):
            VStack(alignment: .trailing, spacing: 6) {
                Text("Correct \(LearnController.minimum) dictations to start learning · \(have) of \(LearnController.minimum)")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(have), total: Double(LearnController.minimum))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("learn.gate")
        case .cloudOnly:
            Text("Learning tunes the cloud setups' prompt. Choose Cloud Flash or Cloud Big in Settings › Model.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("learn.gate")
        case .noKey:
            Text("Add the cloud API key in Settings to learn from your corrections.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("learn.gate")
        }
    }

    private func isMeasured(_ phase: TunePhase) -> Bool { if case .measured = phase { return true } else { return false } }

    private func candidates(_ phase: TunePhase) -> some View {
        let winner = controller.result?.lens
        return VStack(spacing: 8) {
            ForEach(Lens.allCases) { lens in
                let row: (score: Double?, progress: Double, writing: Bool, stage: String?) = {
                    if case .racing(let all) = phase, let p = all[lens] {
                        return (p.score, Double(p.scored) / Double(max(1, p.of)), p.writing,
                                p.scored == p.of ? nil : p.scored == 0 ? "writing…" : "scoring \(p.scored) of \(p.of)")
                    }
                    return (controller.result?.lensScores[lens], 1, false, nil)
                }()
                CandidateRow(lens: lens, score: row.score, progress: row.progress, writing: row.writing, stage: row.stage,
                             state: winner == nil ? .running : winner == lens ? .won : .lost)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func diff(_ result: TuneResult) -> some View {
        let hunks = PromptDiff.hunks(old: controller.setup.promptText, new: result.prompt)
        return VStack(alignment: .leading, spacing: 6) {
            Text("WHAT CHANGED IN THE PROMPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            // A rewrite from top to bottom scrolls instead of pushing the cards away.
            if hunks.reduce(0, { $0 + $1.lines.count }) > 14 {
                ScrollView { hunkList(hunks) }.frame(height: 260)
            } else {
                hunkList(hunks)
            }
            if hunks.isEmpty {
                Text("Nothing: the prompt came back unchanged.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learn.diff")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func hunkList(_ hunks: [PromptDiff.Hunk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hunks) { hunk in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .strikethrough(line.kind == .removed, color: Color(nsColor: .systemRed))
                            .foregroundStyle(line.kind == .context ? AnyShapeStyle(.tertiary) : line.kind == .removed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .added ? Self.good.opacity(0.14) : line.kind == .removed ? Color(nsColor: .systemRed).opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func resultRow(_ result: TuneResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("**Prompt \(controller.nextVersion)** · learned from \(result.errors.count) corrections · \(dates.string(controller.now(), .dateTime.month(.abbreviated).day())) · ~\(result.tokens) tokens")
                    .font(.callout)
                if let verdict = controller.verdictText {
                    Text(verdict).font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityIdentifier("learn.verdict")
                }
            }
            Spacer()
            Button("Discard") { controller.discard() }
                .accessibilityIdentifier("learn.discard")
            Button("Keep \(controller.nextVersion)") { controller.keep() }
                .buttonStyle(.borderedProminent)
                .tint(Self.good)
                .disabled(result.verdict != .pass)
                .accessibilityIdentifier("learn.keep")
        }
        .transition(.opacity)
    }
}

/// A score as a ring and a figure; the delta pill pops in once there is a result.
struct ScoreRing: View {
    let value: Double?
    let before: Double?
    /// Draw the ring green (it went up).
    let up: Bool
    let label: String
    let id: String
    /// "held" when unchanged instead of "+0".
    let deltaAsHeld: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: (value ?? 0) / 100)
                    .stroke(up ? LearnView.good : Color(nsColor: .systemBlue), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: value)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let value {
                        Text("\(Int(value.rounded()))")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: value)
                        Text("%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    } else {
                        Text("Not measured yet")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 40)  // the figure's height, so the card doesn't jump at the first score
                    }
                    if let delta {
                        Text(delta.text)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(delta.good ? LearnView.good : .secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background((delta.good ? LearnView.good : Color.secondary).opacity(0.16), in: Capsule())
                            .padding(.leading, 6)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityIdentifier(id + ".delta")
                    }
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(value.map { "\(Int($0.rounded()))%" } ?? "not measured yet")
        .accessibilityIdentifier(id)
    }

    private var delta: (text: String, good: Bool)? {
        guard let value, let before else { return nil }
        let d = Int(value.rounded()) - Int(before.rounded())
        if d == 0 { return deltaAsHeld ? ("held", false) : nil }
        return (d > 0 ? "+\(d)" : "\(d)", d > 0)
    }
}

/// The Learn button; while a tune runs it carries the app's three colours, moving.
struct LearnButton: View {
    let title: String
    let busy: Bool
    var disabled = false
    let action: () -> Void
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .accessibilityIdentifier("learn.button")
        .onTabShown { if busy && !reduceMotion { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shift = 1 } } }
        // Stops the endless animation while Corrections is hidden behind another tab.
        .onTabHidden { withTransaction(Transaction(animation: nil)) { shift = 0 } }
    }

    private var background: AnyShapeStyle {
        if disabled { return AnyShapeStyle(Color.primary.opacity(0.08)) }
        if busy {
            return AnyShapeStyle(LinearGradient(colors: LearnView.learning + [LearnView.learning[0]],
                                                startPoint: UnitPoint(x: -2 + shift * 2, y: 0.5), endPoint: UnitPoint(x: shift * 2, y: 0.5)))
        }
        return AnyShapeStyle(Color(nsColor: .systemBlue))
    }
}

/// One candidate prompt in the race: name, lens, score so far, a bar that fills a correction at a
/// time, with a highlight running along the unfilled part while a teacher is still writing.
struct CandidateRow: View {
    enum State { case running, won, lost }
    let lens: Lens
    let score: Double?
    let progress: Double
    var writing = false
    /// "writing…", "scoring 7 of 15".
    var stage: String?
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabShown = true

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("\(Text(lens.title).fontWeight(.medium))\(Text(" · \(lens.blurb)").foregroundStyle(.secondary))").font(.callout)
                if state == .won {
                    Text("best").font(.caption2.weight(.semibold)).foregroundStyle(LearnView.good)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(LearnView.good.opacity(0.16), in: Capsule())
                }
                Spacer()
                if let stage {
                    Text(stage).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        .transition(.opacity)
                }
                Text(score.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.callout.weight(state == .won ? .semibold : .regular))
                    .foregroundStyle(state == .won ? LearnView.good : .secondary)
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let filled = geo.size.width * min(1, max(0, progress))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    if writing && !reduceMotion {
                        // A highlight sweeping the unfilled part, once every 1.4 s.
                        TimelineView(.animation(paused: !tabShown)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            let span = geo.size.width - filled, width: CGFloat = 90
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, Color(nsColor: .systemBlue).opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: width)
                                .offset(x: filled - width + (span + width) * t)
                        }
                        .mask(Capsule())
                    }
                    Capsule()
                        .fill(state == .won ? AnyShapeStyle(LearnView.good)
                              : AnyShapeStyle(LinearGradient(colors: LearnView.learning, startPoint: .leading, endPoint: .trailing)))
                        .frame(width: filled)
                        .animation(.spring(duration: 0.35), value: progress)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(state == .lost ? 0.35 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue((score.map { "\(Int($0.rounded()))%" } ?? "running") + (stage.map { " · \($0)" } ?? ""))
        .accessibilityIdentifier("learn.candidate." + lens.rawValue)
        // The sweep stops while Corrections is hidden behind another tab.
        .onTabShown { tabShown = true }
        .onTabHidden { tabShown = false }
    }
}

/// A soft wash that sweeps down the corrections once each time `trigger` changes.
struct SweepOverlay: View {
    let trigger: Int
    @State private var progress: CGFloat = 0
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Color(nsColor: .systemBlue).opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .offset(y: -90 + progress * (geo.size.height + 90))
                .opacity(visible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            progress = 0
            visible = true
            withAnimation(.easeInOut(duration: 1.3)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { visible = false }
        }
    }
}
