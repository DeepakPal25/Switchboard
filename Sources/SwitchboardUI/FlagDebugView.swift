import SwiftUI
import Switchboard

/// An in-app debug menu listing every flag, where it came from, and controls to override it.
///
/// ```swift
/// NavigationStack {
///     FlagDebugView(store: flagStore)
/// }
/// ```
///
/// Or present it as a sheet with ``SwiftUI/View/featureFlagDebugMenu(store:isPresented:)``.
public struct FlagDebugView<Flags: FeatureFlagContainer>: View {
    private let store: FlagStore<Flags>
    @State private var searchText = ""
    @State private var isRefreshing = false

    public init(store: FlagStore<Flags>) {
        self.store = store
    }

    public var body: some View {
        List {
            if !store.overridesEnabled {
                Section {
                    Label("Overrides are disabled in this build.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(filteredDefinitions) { definition in
                    FlagRow(definition: definition, store: store)
                }
            } header: {
                Text("Flags (\(store.definitions.count))")
            }

            if !store.activeConfig.experiments.isEmpty {
                Section("Experiments") {
                    ForEach(store.activeConfig.experiments) { experiment in
                        LabeledContent {
                            Text(store.assignments[experiment.id]?.name ?? "Not enrolled")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(experiment.id)
                                Text("controls \(experiment.flag)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Remote config") {
                LabeledContent("Last refresh", value: store.lastRefreshDate?.formatted(date: .abbreviated, time: .standard) ?? "Never")
                if let error = store.lastRefreshError {
                    LabeledContent("Last error", value: error.localizedDescription)
                }
                LabeledContent("Bucketing ID", value: store.bucketingID)
                if store.pendingConfig != nil {
                    Button("Activate pending config") { store.activatePending() }
                }
                Button {
                    Task {
                        isRefreshing = true
                        defer { isRefreshing = false }
                        try? await store.refresh()
                    }
                } label: {
                    HStack {
                        Text("Refresh now")
                        if isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .navigationTitle("Feature Flags")
        .searchable(text: $searchText, prompt: "Search flags")
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Reset all", role: .destructive) {
                    store.removeAllOverrides()
                }
                .disabled(store.overrides.isEmpty)
            }
        }
    }

    private var filteredDefinitions: [FlagDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.definitions }
        return store.definitions.filter {
            $0.key.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
        }
    }
}

// MARK: - Row

struct FlagRow<Flags: FeatureFlagContainer>: View {
    let definition: FlagDefinition
    let store: FlagStore<Flags>

    var body: some View {
        let current = store.effectiveValue(forKey: definition.key) ?? definition.defaultValue
        let origin = store.origin(forKey: definition.key)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(definition.key)
                    .font(.body.monospaced())
                Spacer()
                OriginBadge(origin: origin)
            }

            if !definition.description.isEmpty {
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.hasTypeMismatch(forKey: definition.key) {
                Label("Wrong type received; using the default.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            editor(current: current)
                .disabled(!store.overridesEnabled)

            if origin == .override {
                Button("Remove override") {
                    store.setOverride(nil, forKey: definition.key)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func editor(current: FlagRawValue) -> some View {
        if let options = definition.options {
            Picker("Value", selection: Binding(
                get: { current },
                set: { store.setOverride($0, forKey: definition.key) }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option.displayString).tag(option)
                }
            }
        } else if case .bool(let isOn) = current {
            Toggle("Enabled", isOn: Binding(
                get: { isOn },
                set: { store.setOverride(.bool($0), forKey: definition.key) }
            ))
        } else {
            ValueField(definition: definition, current: current) { newValue in
                store.setOverride(newValue, forKey: definition.key)
            }
        }
    }
}

/// A text field for number and string flags that commits on submit.
private struct ValueField: View {
    let definition: FlagDefinition
    let current: FlagRawValue
    let commit: (FlagRawValue) -> Void

    @State private var text: String
    @State private var isInvalid = false

    init(definition: FlagDefinition, current: FlagRawValue, commit: @escaping (FlagRawValue) -> Void) {
        self.definition = definition
        self.current = current
        self.commit = commit
        _text = State(initialValue: current.displayString)
    }

    var body: some View {
        HStack {
            TextField("Value", text: $text)
                .onSubmit(submit)
                .autocorrectionDisabled()
            if isInvalid {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Invalid value")
            }
        }
        .onChange(of: current) { _, newValue in
            text = newValue.displayString
            isInvalid = false
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed: FlagRawValue? = switch definition.defaultValue {
        case .int: Int(trimmed).map(FlagRawValue.int)
        case .double: Double(trimmed).map(FlagRawValue.double)
        case .string: .string(text)
        case .bool: Bool(trimmed).map(FlagRawValue.bool)
        }
        guard let parsed else {
            isInvalid = true
            return
        }
        isInvalid = false
        commit(parsed)
    }
}

private struct OriginBadge: View {
    let origin: FlagOrigin

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch origin {
        case .override: "OVERRIDE"
        case .experiment(_, let variant): "A/B · \(variant)"
        case .remote: "REMOTE"
        case .default: "DEFAULT"
        }
    }

    private var color: Color {
        switch origin {
        case .override: .orange
        case .experiment: .purple
        case .remote: .blue
        case .default: .gray
        }
    }
}

// MARK: - Presentation

extension View {
    /// Presents ``FlagDebugView`` in a sheet, e.g. from a shake gesture or a hidden settings row.
    public func featureFlagDebugMenu<Flags: FeatureFlagContainer>(
        store: FlagStore<Flags>,
        isPresented: Binding<Bool>
    ) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                FlagDebugView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented.wrappedValue = false }
                        }
                    }
            }
        }
    }
}
