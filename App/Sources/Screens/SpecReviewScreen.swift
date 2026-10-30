import AgentCore
import SwiftUI

struct SpecReviewScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let specID: UUID
    @State private var text = ""
    @State private var loadedStage: SpecStage?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let spec = app.specs.specs.first(where: { $0.id == specID }) {
                content(spec)
                    .navigationTitle(spec.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Delete spec", role: .destructive) { confirmDelete = true }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                    .alert("Delete this spec record?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { Task { await app.specs.delete(spec.id) } }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Files already saved in the project repo are left alone.") }
            } else {
                ProgressView().task { await app.specs.load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ spec: SpecRecord) -> some View {
        if spec.stage == .execution || spec.stage == .completed {
            List {
                Section {
                    Label(spec.stage == .completed ? "Spec complete" : "Approved and saved", systemImage: spec.stage == .completed ? "checkmark.seal.fill" : "checkmark.seal")
                    Text(".kiro/specs/\(spec.slug)/").font(.caption.monospaced()).foregroundStyle(Theme.secondaryText)
                    if let pull = spec.saveReceipt?.pullRequest, spec.saveReceipt?.resolution == nil {
                        Button("Open pull request") { if let url = URL(string: pull.htmlURL) { openURL(url) } }
                        Button("Add it") { Task { await app.specs.addIt(spec) } }.buttonStyle(.borderedProminent)
                        Button("Throw away", role: .destructive) { Task { await app.specs.throwAway(spec) } }
                    }
                }
                Section("Tasks") {
                    if spec.saveReceipt?.pullRequest != nil, spec.saveReceipt?.resolution == nil {
                        Text("Add the approved spec before running its tasks.").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(spec.tasks) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isComplete ? .green : Theme.secondaryText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title)
                                if spec.activeTaskID == task.id { Label("Working…", systemImage: "gearshape.2").font(.caption).foregroundStyle(Theme.secondaryText) }
                            }
                            Spacer()
                            if !task.isComplete, spec.activeJobID == nil,
                               !(spec.saveReceipt?.pullRequest != nil && spec.saveReceipt?.resolution == nil) {
                                Button("Run") { Task { await app.specs.execute(task, in: spec) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .refreshable { await app.jobs.refresh(); await app.specs.refreshJobs() }
            .task { await app.specs.refreshJobs() }
        } else {
            Form {
                Section {
                    stageProgress(spec)
                }
                if spec.activeJobID != nil, spec.artifact(for: spec.stage).isEmpty {
                    Section {
                        HStack { ProgressView(); Text("\(spec.stage.title) is being drafted…") }
                        Button("Show job") { app.jobs.show(spec.activeJobID) }
                        Button("Check for result") { Task { await app.jobs.refresh(); await app.specs.refreshJobs() } }
                    }
                } else {
                    Section(spec.stage.title) {
                        TextEditor(text: $text).frame(minHeight: 320).font(.body)
                    }
                    Section {
                        Button("Save edits") { Task { _ = await app.specs.saveArtifact(spec, stage: spec.stage, text: text) } }
                        Button("Approve \(spec.stage.title.lowercased())") { Task { await app.specs.approve(spec, text: text) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("Approval moves to the next stage. Requirements, design, checked design, and tasks are approved in that order.")
                    }
                }
            }
            .onAppear { loadText(spec) }
            .onChange(of: spec.stage) { _, _ in loadText(spec) }
            .onChange(of: spec.updatedAt) { _, _ in loadText(spec) }
        }
    }

    private func stageProgress(_ spec: SpecRecord) -> some View {
        HStack {
            ForEach([SpecStage.requirements, .design, .checkedDesign, .tasks], id: \.self) { stage in
                VStack(spacing: 4) {
                    Image(systemName: spec.approvedStages.contains(stage) ? "checkmark.circle.fill" : spec.stage == stage ? "circle.inset.filled" : "circle")
                    Text(stage == .checkedDesign ? "Check" : stage.title).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(spec.approvedStages.contains(stage) ? .green : Theme.secondaryText)
                if stage != .tasks { Spacer(); Rectangle().fill(Theme.stroke).frame(height: 1); Spacer() }
            }
        }
    }

    private func loadText(_ spec: SpecRecord) {
        guard loadedStage != spec.stage || text.isEmpty else { return }
        loadedStage = spec.stage
        text = spec.artifact(for: spec.stage)
    }
}
