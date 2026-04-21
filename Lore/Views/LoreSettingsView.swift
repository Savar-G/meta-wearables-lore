import SwiftUI

struct LoreSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var apiKey: String = LoreSecrets.apiKey ?? ""
  @State private var selectedModel: String = LoreSecrets.model
  @State private var showAPIKey: Bool = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            if showAPIKey {
              TextField("sk-or-v1-…", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } else {
              SecureField("sk-or-v1-…", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }
            Button {
              showAPIKey.toggle()
            } label: {
              Image(systemName: showAPIKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
          }
        } header: {
          Text("OpenRouter API Key")
        } footer: {
          Text("Get a key at openrouter.ai. Stored locally in UserDefaults; never sent anywhere except OpenRouter.")
        }

        Section {
          Picker("Model", selection: $selectedModel) {
            ForEach(LoreConfig.availableModels, id: \.self) { model in
              Text(model).tag(model)
            }
          }
        } header: {
          Text("Vision Model")
        } footer: {
          Text("Any vision-capable OpenRouter model works. Default: \(LoreConfig.defaultModel).")
        }
      }
      .navigationTitle("Lore Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            LoreSecrets.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            LoreSecrets.model = selectedModel
            dismiss()
          }
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
