// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation

enum GmailDraftUploader {

    enum UploadError: Error, LocalizedError {
        case tempFileFailed
        case curlFailed(String)

        var errorDescription: String? {
            switch self {
            case .tempFileFailed:   return "Could not write temporary email file."
            case .curlFailed(let m): return "IMAP upload failed: \(m)"
            }
        }
    }

    /// APPENDs `emlData` to Gmail's Drafts mailbox via IMAP over TLS using curl.
    /// Runs on a background thread; safe to call from async context.
    static func upload(emlData: Data, credentials: GmailCredentials) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogcomposer_draft_\(UUID().uuidString).eml")

        do {
            try emlData.write(to: tmp)
        } catch {
            throw UploadError.tempFileFailed
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Try candidate mailbox names in order. "[Gmail]/Drafts" is standard English Gmail;
        // some locales use "[Google Mail]/Drafts". We try both before giving up.
        let mailboxes = ["[Gmail]/Drafts", "[Google Mail]/Drafts", "Drafts"]
        var lastError = ""

        for mailbox in mailboxes {
            // Percent-encode square brackets per RFC 3986 §2.2 (reserved in path components).
            let encoded = mailbox
                .replacingOccurrences(of: "[", with: "%5B")
                .replacingOccurrences(of: "]", with: "%5D")
                .replacingOccurrences(of: " ", with: "%20")
            let url = "imaps://imap.gmail.com:993/\(encoded)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--url",         url,
                "--user",        "\(credentials.email):\(credentials.appPassword)",
                "--upload-file", tmp.path,
                "--ssl-reqd",
                "--verbose"      // verbose so the IMAP server response appears in stderr
            ]

            let errPipe = Pipe()
            let outPipe = Pipe()
            process.standardError  = errPipe
            process.standardOutput = outPipe

            try process.run()

            let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }
            let outTask = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }

            let errData = await errTask.value
            _ = await outTask.value

            if process.terminationStatus == 0 { return }

            let raw = String(data: errData, encoding: .utf8) ?? ""
            // Extract only server-response lines (< ...) and drop lines that echo credentials.
            let serverLines = raw.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("< ") || ($0.hasPrefix("*") && !$0.contains("password")) }
                .map { String($0.dropFirst(2)) }   // strip the leading "< " or "* "
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = serverLines.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : serverLines
        }

        throw UploadError.curlFailed(lastError.isEmpty ? "(no server response)" : lastError)
    }
}
