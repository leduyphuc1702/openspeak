import SwiftUI

struct PhonemeDetailView: View {
    let phoneme: Phoneme
    @Environment(ProgressStore.self) private var progress
    @Environment(ContentStore.self) private var content

    private var unit: CourseUnit? { content.units.first(where: { $0.sounds.contains(phoneme.id) }) }

    private var kind: String {
        guard let voiced = phoneme.voiced else { return phoneme.group }
        return "\(phoneme.group) · \(voiced ? "Hữu thanh (rung dây thanh)" : "Vô thanh")"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 14) {
                    Text("/\(phoneme.symbol)/")
                        .font(.system(size: 72, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text(kind).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    Button {
                        Haptics.tap()
                        SpeechPlayer.shared.speak(phoneme: phoneme)
                    } label: {
                        Label("Nghe âm", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .background(.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                ArticulationCard(phoneme: phoneme)

                if let skill = progress.soundSkill(phoneme.id) {
                    ScoreBar(title: "Điểm nói gần đây", score: skill, systemImage: "waveform").card()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Từ ví dụ").font(.headline).padding(.bottom, 6)
                    ForEach(phoneme.examples) { example in
                        ExampleRow(example: example, phonemeID: phoneme.id)
                        if example != phoneme.examples.last { Divider() }
                    }
                }
                .card()
            }
            .padding(20)
        }
        .actionBar(isPresented: unit != nil) {
            if let unit {
                TaskLink {
                    SoundLessonView(phoneme: phoneme, unit: unit)
                } label: {
                    Label(progress.isLessonDone(phoneme.id) ? "Học lại bài này" : "Vào bài học",
                          systemImage: progress.isLessonDone(phoneme.id) ? "checkmark.seal.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(color: progress.isLessonDone(phoneme.id) ? Theme.good : Theme.primary))
            }
        }
        .screenBackground()
        .inlineNavigationTitle("Âm /\(phoneme.symbol)/")
    }
}

private struct ExampleRow: View {
    let example: WordEntry
    let phonemeID: String
    @State private var showMouth = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(example.word).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(IPATokenizer.highlighted(example, phonemeID: phonemeID))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                SpeechPlayer.shared.speak(example.word)
            } label: {
                IconBadge(systemImage: "speaker.wave.2.fill", size: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nghe \(example.word)")
            Button { showMouth = true } label: {
                IconBadge(systemImage: "mouth.fill", size: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Khẩu hình cả từ \(example.word)")
            .sheet(isPresented: $showMouth) {
                MouthGuideSheet(phoneIDs: example.phones, item: PracticeItem(word: example, focus: phonemeID))
            }
            TaskLink {
                SpeakingSessionView(item: PracticeItem(word: example, focus: phonemeID))
            } label: {
                IconBadge(systemImage: "mic.fill", color: Theme.accent, size: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Luyện nói \(example.word)")
        }
        .padding(.vertical, 6)
    }
}
