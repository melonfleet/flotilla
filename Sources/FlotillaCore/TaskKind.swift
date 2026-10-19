import Foundation

/// What sort of job a task is: the one thing that decides whether the Tasks drawer may offer Retry
/// or Cancel on it (Q63, round 2, Kamal 19 October — "no controls that pretend").
///
/// **Each call site that starts a job names its kind, and the kind answers both questions.** A job
/// that says nothing is `.unclassified`, which offers neither: the safe answer is the one that
/// needs no one to have remembered.
///
/// *Retry* means "run the same `AppModel` call again with the arguments it had". It is allowed only
/// where running it twice, after the first attempt failed part-way, cannot do harm: a pull or a
/// transfer re-does what is missing; a create that was refused made nothing. A job that may have
/// half-applied — a container run (volume ownership, then the container), a stack, a cluster, a
/// machine, an import, a push to several Macs where some already took it, DNS setup that restarts
/// a runtime — says no, and the user goes back to the screen that has their choices.
///
/// *Cancel* means ending the job's own child process, part-way. It is allowed only for a pull or a
/// build on this Mac, whose process we hold and which leaves nothing behind but a cache. Anything
/// that runs through the privileged helper, a `container` install or upgrade, or a host update is
/// never cancellable here, whatever its kind: stopping those mid-change leaves a half-installed
/// package. None of those is a task at all today; the rule is written down so a future one is
/// declared `false` by default.
public enum TaskKind: String, Sendable, CaseIterable {
    case pullImage
    case pullImageToHosts
    case buildImage
    case sendImage
    case createVolume
    case createNetwork
    case pushDefinition
    case runContainer
    case createStack
    case createCluster
    case recreateCluster
    case clusterAction
    case createMachine
    case importConfiguration
    case groupAction
    case dnsSetup
    case unclassified

    public var canRetry: Bool {
        switch self {
        case .pullImage, .pullImageToHosts, .buildImage, .sendImage, .createVolume, .createNetwork,
             .clusterAction, .groupAction:
            true
        case .pushDefinition, .runContainer, .createStack, .createCluster, .recreateCluster,
             .createMachine, .importConfiguration, .dnsSetup, .unclassified:
            false
        }
    }

    public var canCancel: Bool {
        switch self {
        case .pullImage, .buildImage: true
        default: false
        }
    }

    /// The section a job is started from, for the row's "where".
    public var section: String {
        switch self {
        case .pullImage, .pullImageToHosts, .buildImage, .sendImage: "Images"
        case .createVolume: "Volumes"
        case .createNetwork: "Networks"
        case .pushDefinition: "Hosts"
        case .runContainer, .groupAction: "Containers"
        case .createStack: "Suggestions"
        case .createCluster, .recreateCluster, .clusterAction: "Clusters"
        case .createMachine: "Machines"
        case .importConfiguration: "Import"
        case .dnsSetup: "DNS"
        case .unclassified: "Flotilla"
        }
    }
}
