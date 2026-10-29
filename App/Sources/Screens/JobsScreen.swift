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
            .confirmationDialog("Delete this job?", isPresented: $showsDelete, titleVisibility: .visible) {
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
                    link("IPA", result.artifactURL)
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
        .confirmationDialog("Delete this job?", isPresented: $showsDelete, titleVisibility: .visible) {
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
    }

    private var progress: Double {
        guard !current.steps.isEmpty else { return 0 }
        return Double(current.steps.filter { $0.status == .done }.count) / Double(current.steps.count)
    }

    @ViewBuilder private func link(_ title: String, _ value: String?) -> some View {
        if let value, let url = URL(string: value) { Button(title) { openURL(url) } }
    }

    private var statusText: String {
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
