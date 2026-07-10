import Foundation

/// Single source of truth for project identity, attribution, and donation addresses — reused by the
/// Support screen and kept in sync with the cross-platform docs (see docs/DONATIONS.md). Deliberately
/// contains no author/AI identifiers so the public repo can stay anonymous.
enum ProjectInfo {
    static let appName = "NOOP"
    static let tagline = "Your strap. Your data. Your machine. Local-first, no cloud."
    static let version = "0.1.0"
    /// Public contact for questions, feedback, bug reports. Baked into every platform.
    static let contactEmail = "thenoopapp@gmail.com"

    /// Open-source reverse-engineering this is built on.
    static let attributions: [(repo: String, note: String)] = [
        ("johnmiddleton12/my-whoop", "WHOOP BLE protocol"),
        ("b-nnett/goose", "WHOOP 5.0 BLE protocol"),
    ]

    /// Optional, never-required donation addresses. Framed as support, not a paywall.
    static let donations: [CryptoAddress] = [
        .init(symbol: "BTC", name: "Bitcoin",
              address: "bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5"),
        .init(symbol: "ADA", name: "Cardano",
              address: "addr1qxsju3y0mlke2h6h2g6qgnq4r3jstngtyjxs0nnp5zrv28zv8p5rgzruxyjz33j9k23pffta8z639e2snjdd4vcetfqsn4vwr3"),
        .init(symbol: "ETH", name: "Ethereum",
              address: "0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F"),
        .init(symbol: "XRP", name: "XRP",
              address: "rpvijHi2nVY9WWAJhojsAX5tJmHdmLtFhq"),
    ]

    struct CryptoAddress: Identifiable {
        let symbol: String
        let name: String
        let address: String
        var id: String { symbol }
    }
}
