import Foundation

/// When an admin Mac browses Bonjour for hosts. Browsing is what makes macOS show its Local
/// Network prompt, so a fresh admin waits until the user opens Hosts or starts adding one — the
/// prompt then arrives with a reason. An admin that already trusts hosts browses from launch:
/// reaching them may rely on the advertised endpoint (`PeerBook.reach`), and they have been
/// through Add Host. A host-only Mac never browses.
public enum DiscoveryPolicy {
    public static func shouldBrowse(isAdmin: Bool, trustedHostCount: Int, userOpenedHosts: Bool) -> Bool {
        guard isAdmin else { return false }
        return trustedHostCount > 0 || userOpenedHosts
    }
}
