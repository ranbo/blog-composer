// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation

/// Looks up a YouTube video's true frame shape so its embed can be sized without
/// letterboxing.
///
/// The watch page's `og:video:width` / `og:video:height` are the only reliable source:
/// the oEmbed endpoint reports 1920x1080 even for 9:16 Shorts, and the original-aspect
/// thumbnail (`oardefault.jpg`) is missing for most portrait uploads.
enum VideoAspect {

    static let landscape = (w: 16, h: 9)

    private static let widthPattern  = #"og:video:width" content="(\d+)""#
    private static let heightPattern = #"og:video:height" content="(\d+)""#

    /// Returns the video's aspect, or nil if it could not be determined (offline,
    /// private video, page layout changed).  Callers keep their 16:9 default on nil.
    static func fetch(videoId: String,
                      session: URLSession = .shared) async -> (w: Int, h: Int)? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return nil }
        var request = URLRequest(url: url)
        // Without a browser UA YouTube serves a consent interstitial with no og: tags.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        guard let w = firstInt(in: html, pattern: widthPattern),
              let h = firstInt(in: html, pattern: heightPattern),
              w > 0, h > 0
        else { return nil }

        return (w, h)
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return Int(text[r])
    }
}
