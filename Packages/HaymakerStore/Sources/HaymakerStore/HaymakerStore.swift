import HaymakerKit

/// HaymakerStore persistence layer namespace.
///
/// M1 provides the package skeleton and wiring stub.
/// M4 implements the GRDB append-only bout ledger, derived records, and
/// settings; M5 adds the versioned backup codec and CSV export models.
public enum HaymakerStore {
    /// Namespace identifier.
    public static let domain = "HaymakerStore"

    /// Current persistence schema milestone marker.
    public static let milestone = "M1-skeleton"
}
