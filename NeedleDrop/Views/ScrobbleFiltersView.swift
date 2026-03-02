import SwiftUI

/// View for managing scrobble filter rules on the remote scrobbler.
struct ScrobbleFiltersView: View {
    @EnvironmentObject var appState: AppState

    @State private var rules: [FilterRule] = []
    @State private var minDuration: Int = 90
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading filters…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            } else {
                // Min duration
                HStack {
                    Text("Min duration:")
                        .font(.caption)
                    TextField("", value: $minDuration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .font(.caption)
                    Text("seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)

                // Rules list
                ForEach($rules) { $rule in
                    HStack(spacing: 4) {
                        Picker("", selection: $rule.type) {
                            Text("Artist").tag(FilterRule.FilterType.artistExclude)
                            Text("Title").tag(FilterRule.FilterType.titleExclude)
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        .font(.caption)

                        TextField("Pattern", text: $rule.pattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))

                        Button {
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                }

                // Add rule button
                Button {
                    rules.append(FilterRule(pattern: "", type: .artistExclude))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)

                // Save button
                HStack {
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    } else if let msg = successMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    Spacer()

                    Button(action: saveFilters) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSaving)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 4)
        .onAppear { loadFilters() }
    }

    private func loadFilters() {
        isLoading = true
        Task {
            do {
                let result = try await appState.scrobblerClient.getFilters()
                minDuration = result.minDuration
                rules = result.rules
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func saveFilters() {
        isSaving = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                // Filter out empty rules
                let validRules = rules.filter { !$0.pattern.isEmpty }
                try await appState.scrobblerClient.setFilters(
                    minDuration: minDuration,
                    rules: validRules
                )
                isSaving = false
                successMessage = "Filters saved"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    successMessage = nil
                }
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
