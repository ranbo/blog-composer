// Copyright © 2026 Randy Wilson. All rights reserved.

import SwiftUI

struct GmailSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var appPassword: String = ""
    @State private var errorMessage: String = ""

    let onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Gmail Setup")
                .font(.headline)

            Text("""
                Enter your Gmail address and an App Password. \
                Generate one at:\nGoogle Account → Security → 2-Step Verification → App passwords
                """)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Gmail address:")
                        .gridColumnAlignment(.trailing)
                    TextField("you@gmail.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                GridRow {
                    Text("App password:")
                        .gridColumnAlignment(.trailing)
                    SecureField("xxxx xxxx xxxx xxxx", text: $appPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || appPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
        .onAppear {
            if let saved = KeychainHelper.load() {
                email = saved.email
            }
        }
    }

    private func save() {
        let cleanedPassword = appPassword.replacingOccurrences(of: " ", with: "")
        let cleanedEmail    = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let creds = GmailCredentials(email: cleanedEmail, appPassword: cleanedPassword)
        do {
            try KeychainHelper.save(creds)
            dismiss()
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
