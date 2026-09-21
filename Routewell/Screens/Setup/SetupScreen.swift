import SwiftUI
import RoutewellKit

/// A pure, unit-testable model for the setup form's validation. It never
/// touches SwiftUI so `RoutewellTests` can exercise every branch directly.
struct SetupFormState: Equatable {
    var addressText: String = ""
    var username: String = "root"
    var password: String = ""
    var plainHTTPAcknowledged: Bool = false

    struct SetupValidation {
        let endpoint: Result<RouterEndpoint, EndpointParseError>
        let usernameProblem: String?
        let passwordProblem: String?
        let plainHTTPNeedsAck: Bool
        let canSave: Bool
    }

    func validate() -> SetupValidation {
        let endpoint: Result<RouterEndpoint, EndpointParseError>
        do {
            endpoint = .success(try RouterEndpoint.parse(addressText))
        } catch {
            endpoint = .failure(error)
        }

        let usernameProblem = username.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Enter a username." : nil
        let passwordProblem = password.isEmpty ? "Enter a password." : nil

        var plainHTTPNeedsAck = false
        if case .success(let value) = endpoint, value.scheme == .http {
            plainHTTPNeedsAck = !plainHTTPAcknowledged
        }

        let endpointIsValid = (try? endpoint.get()) != nil
        let canSave = endpointIsValid && usernameProblem == nil && passwordProblem == nil && !plainHTTPNeedsAck

        return SetupValidation(
            endpoint: endpoint,
            usernameProblem: usernameProblem,
            passwordProblem: passwordProblem,
            plainHTTPNeedsAck: plainHTTPNeedsAck,
            canSave: canSave
        )
    }
}

extension EndpointParseError {
    /// Plain-language text shown under the address field. Never echoes the
    /// typed text back — only the user's own settings fields do that.
    var message: String {
        switch self {
        case .empty, .missingHost: "Enter a router address."
        case .invalidScheme: "Use http:// or https://, or leave the scheme off."
        case .invalidHost: "This does not look like a valid hostname or IP address."
        case .invalidPort: "Port must be a number between 1 and 65535."
        case .userInfoNotAllowed: "Remove the username and password from the address."
        case .pathNotAllowed: "Remove the path from the address."
        case .queryNotAllowed: "Remove the query from the address."
        }
    }
}

struct SetupScreen: View {
    let environment: AppEnvironment
    @State private var form = SetupFormState()
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        let validation = form.validate()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect your router").font(.title2).fontWeight(.semibold)
                Text("Add your router's address to start using Routewell.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Router address", text: $form.addressText, prompt: Text("192.168.8.1"))
                        .textFieldStyle(.roundedBorder)
                    if !form.addressText.isEmpty, case .failure(let error) = validation.endpoint {
                        Text(error.message).font(.caption).foregroundStyle(.red)
                    }
                }

                TextField("Username", text: $form.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $form.password)
                    .textFieldStyle(.roundedBorder)

                if case .success(let endpoint) = validation.endpoint, endpoint.scheme == .http {
                    Toggle(isOn: $form.plainHTTPAcknowledged) {
                        Text("This router uses plain HTTP. I understand credentials are sent unencrypted on my local network.")
                    }
                    .toggleStyle(.checkbox)
                }

                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(.red)
                }

                Button("Save router") {
                    Task { await save(validation: validation) }
                }
                .disabled(!validation.canSave || isSaving)

                Text("SSH uses key files or the SSH agent only. Routewell never asks for an SSH password.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save(validation: SetupFormState.SetupValidation) async {
        guard case .success(let endpoint) = validation.endpoint else { return }
        isSaving = true
        defer { isSaving = false }
        let password = Data(form.password.utf8)
        form.password = ""
        let saved = await environment.saveLiveRouterProfile(
            endpoint: endpoint,
            username: form.username.trimmingCharacters(in: .whitespaces),
            password: password,
            plainHTTPAcknowledged: form.plainHTTPAcknowledged
        )
        saveError = saved ? nil : "Could not save the router. Try again."
    }
}
