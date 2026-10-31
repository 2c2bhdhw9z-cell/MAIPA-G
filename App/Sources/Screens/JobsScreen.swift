import AgentCore
import SwiftUI

struct JobsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var deletingJob: JobRecord?
    @State private var showsDelete = false

    var body: some View {
        NavigationStack {
            List {
                if app.jobs.jobs.isEmpty {
                    ContentUnavailableView("No jobs yet", systemImage: "gearshape.2", description: Text("Autonomous repo work shows up here."))
                } else {
                    ForEach(app.jobs.jobs) { job in
                        NavigationLink(value: job.id) { JobRow(job: job) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { askToDelete(job) } label: { Label("Delete", systemImage: "trash") }
                                    .tint(Theme.danger)
                            }
                            .contextMenu {
                                Button(role: .destructive) { askToDelete(job) } label: { Label("Delete job", systemImage: "trash") }
                            }
                    }
                }
            }
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let job = app.jobs.jobs.first(where: { $0.id == id }) {
                    JobDetailScreen(job: job)
                } else {
                    ContentUnavailableView("Job unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .refreshable { await app.jobs.refresh() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Delete this job?", isPresented: $showsDelete) {
                Button("Delete job", role: .destructive) {
                    if let id = deletingJob?.id { Task { await app.jobs.delete(id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
        }
        .task { if !PreviewScenes.isActive { await app.jobs.refresh() } }
    }

    private func askToDelete(_ job: JobRecord) {
        deletingJob = job
        showsDelete = true
    }

    private var deleteMessage: String {
        guard let job = deletingJob else { return "This removes the saved job." }
        return [.done, .failed, .stopped].contains(job.status)
            ? "This removes the saved job from this phone and MAIPA-G-data."
            : "This stops the GitHub run, then removes the saved job from this phone and MAIPA-G-data."
    }
}

private struct JobRow: View {
    var job: JobRecord
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(job.status == .failed ? Theme.danger : Theme.secondaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(status) · \(job.cumulativeCost.dollars)")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if [.queued, .settingUp, .running, .handingOver].contains(job.status) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var status: String {
        if job.isStuck { return "Stuck — no progress for 10 minutes" }
        switch job.status {
        case .queued: return "Waiting"
        case .settingUp: return "Setting up"
        case .running: return "Working"
        case .needsApproval, .needsAnswer: return "Needs you"
        case .handingOver: return "Changing runners"
        case .done: return "Finished"
        case .stopped: return "Stopped"
        case .failed: return "Didn't finish"
        }
    }

    private var icon: String {
        switch job.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsApproval, .needsAnswer: return "person.crop.circle.badge.questionmark"
        case .stopped: return "stop.circle"
        default: return "gearshape.2"
        }
    }
}

struct JobDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var showsDelete = false
    @State private var isDownloadingIPA = false
    @State private var downloadError: String?
    var job: JobRecord

    private var current: JobRecord { app.jobs.jobs.first(where: { $0.id == job.id }) ?? job }

    var body: some View {
        List {
            Section {
                HStack {
                    Label(statusText, systemImage: statusIcon)
                    Spacer()
                    Text(current.cumulativeCost.dollars).monospacedDigit().foregroundStyle(Theme.secondaryText)
                }
                if !current.steps.isEmpty {
                    ProgressView(value: progress)
                    Text("\(current.steps.filter { $0.status == .done }.count) of \(current.steps.count) steps")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }

            if !current.questions.filter({ $0.answer == nil }).isEmpty {
                Section("Needs you") {
                    ForEach(current.questions.filter { $0.answer == nil }) { question in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(question.text).font(.body.weight(.medium))
                            ForEach(question.options, id: \.self) { option in
                                if option == question.options.first {
                                    Button(option) { Task { await app.jobs.answer(current.id, questionID: question.id, answer: option) } }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button(option) { Task { await app.jobs.answer(current.id, questionID: question.id, answer: option) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Progress") {
                ForEach(current.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: stepIcon(step.status)).foregroundStyle(Theme.secondaryText).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
            }

            if let result = current.result {
                Section("Result") {
                    Text(result.summary).textSelection(.enabled)
                    if result.pullRequest != nil {
                        HStack {
                            Button("Add it") { Task { await app.jobs.addIt(current.id) } }.buttonStyle(.borderedProminent)
                            Button("Throw away", role: .destructive) { Task { await app.jobs.throwAway(current.id) } }.buttonStyle(.bordered)
                        }
                    }
                    link("Pull request", result.pullRequest?.htmlURL)
                    link("Build", result.buildURL)
                    if let artifactURL = result.artifactURL, !artifactURL.isEmpty {
                        Button {
                            Task { await downloadArtifact(artifactURL) }
                        } label: {
                            HStack(spacing: 8) {
                                if isDownloadingIPA { ProgressView().controlSize(.small) }
                                Label(isDownloadingIPA ? "Downloading IPA…" : "Download IPA", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .disabled(isDownloadingIPA)
                    }
                }
            }

            if current.status == .failed, current.result == nil {
                Section("Result") {
                    Text("This older job stopped without saving the reason. You can Resume it with the fixed runner or delete it below.")
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            Section {
                link("Open run", current.workflowRunURL)
                link("Open logs", current.logsURL)
                if [.queued, .settingUp, .running, .handingOver, .needsApproval, .needsAnswer].contains(current.status) {
                    if current.isStuck {
                        Text("No progress has been saved for 10 minutes.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("Stop and resume") { Task { await app.jobs.restart(current.id) } }
                    }
                    Button("Stop job", role: .destructive) { Task { await app.jobs.stop(current.id) } }
                } else if current.status == .stopped || current.status == .failed {
                    Button("Resume") { Task { await app.jobs.resume(current.id) } }
                }
                Button("Delete job", role: .destructive) { showsDelete = true }
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.jobs.refresh() }
        .alert("Delete this job?", isPresented: $showsDelete) {
            Button("Delete job", role: .destructive) {
                Task {
                    await app.jobs.delete(current.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text([.done, .failed, .stopped].contains(current.status)
                 ? "This removes the saved job from this phone and MAIPA-G-data."
                 : "This stops the GitHub run, then removes the saved job from this phone and MAIPA-G-data.")
        }
        .alert("Couldn't download IPA", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK") { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
    }

    private func downloadArtifact(_ rawURL: String) async {
        guard !isDownloadingIPA else { return }
        guard let github = app.github.client else {
            if let url = URL(string: rawURL) { openURL(url) }
            return
        }
        isDownloadingIPA = true
        defer { isDownloadingIPA = false }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-artifact-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let isZipEndpoint = rawURL.lowercased().hasSuffix("/zip") || rawURL.lowercased().hasSuffix(".zip")
        let downloadedURL = workDir.appendingPathComponent(isZipEndpoint ? "MAIPA-G-Artifact.zip" : "MAIPA-G.ipa")
        do {
            try await github.downloadAuthenticatedArtifact(at: rawURL, to: downloadedURL)
            var shareTarget = downloadedURL
            if isZipEndpoint,
               let attrs = try? FileManager.default.attributesOfItem(atPath: downloadedURL.path),
               let size = attrs[.size] as? Int,
               size > 0, size <= 128 * 1_048_576,
               let zipData = try? Data(contentsOf: downloadedURL, options: .mappedIfSafe) {
                let unpackDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
                if (try? PreviewArtifactExtractor.extract(zipData, to: unpackDir)) != nil,
                   let foundIPA = Self.firstIPAFile(in: unpackDir) {
                    shareTarget = foundIPA
                }
            }
            SharePresenter.present(items: [shareTarget])
        } catch {
            downloadError = app.github.describe(error)
        }
    }

    private nonisolated static func firstIPAFile(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        while let next = enumerator.nextObject() {
            if let fileURL = next as? URL, fileURL.pathExtension.lowercased() == "ipa" {
                return fileURL
            }
        }
        return nil
    }

    private var progress: Double {
        guard !current.steps.isEmpty else { return 0 }
        return Double(current.steps.filter { $0.status == .done }.count) / Double(current.steps.count)
    }

    @ViewBuilder private func link(_ title: String, _ value: String?) -> some View {
        if let value, let url = URL(string: value) { Button(title) { openURL(url) } }
    }

    private var statusText: String {
        if current.isStuck { return "Stuck — no progress for 10 minutes" }
        switch current.status {
        case .queued: return "Waiting for GitHub"
        case .settingUp: return "Setting up Autonomous"
        case .running: return "Working on GitHub"
        case .needsApproval, .needsAnswer: return "Needs you"
        case .handingOver: return "Saving and changing runners"
        case .done: return "Finished"
        case .stopped: return "Stopped"
        case .failed: return "Didn't finish"
        }
    }

    private var statusIcon: String {
        switch current.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case .needsApproval, .needsAnswer: return "person.crop.circle.badge.questionmark"
        case .stopped: return "stop.circle"
        default: return "gearshape.2"
        }
    }

    private func stepIcon(_ status: JobStepRecord.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "person.crop.circle.badge.questionmark"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }
}
