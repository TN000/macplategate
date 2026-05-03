import Foundation

/// Nahradí hesla v URL (user:pass@host) + běžné token-like query params za ***.
/// Použito v logování URL (RTSP, webhook) do spz.log, aby credentials nebyly
/// v plaintext na disku.
enum LogSanitizer {
    static func sanitizeURL(_ s: String) -> String {
        var out = s
        // 1) user:password@host → user:***@host
        out = out.replacingOccurrences(
            of: #"(://[^:/@\s]+):[^@/\s]+@"#,
            with: "$1:***@",
            options: .regularExpression)
        // 2) ?token=X / &key=X / &api_key=X / &password=X / &pass=X / &auth=X → ***
        out = out.replacingOccurrences(
            of: #"([?&](?:token|api[_-]?key|key|password|pass|auth|secret)=)[^&#\s]+"#,
            with: "$1***",
            options: [.regularExpression, .caseInsensitive])
        return out
    }
}
