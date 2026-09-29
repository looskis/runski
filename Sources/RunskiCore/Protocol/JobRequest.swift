import Foundation

/// A job as dispatched by the Actions service (`PipelineAgentJobRequest` body, or
/// the response of the run service's `acquirejob`).
public struct AgentJobRequestMessage: Codable, Sendable {
    public struct Plan: Codable, Sendable {
        public var scopeIdentifier: String?
        public var planId: String
        public var planType: String?
        public var version: Int?
        public var artifactUri: String?
        public var hubName: String { planType ?? "actions" }
        public var scope: String { scopeIdentifier ?? "00000000-0000-0000-0000-000000000000" }
    }
    public struct TimelineReference: Codable, Sendable {
        public var id: String
        public var changeId: Int?
    }
    public struct EndpointAuthorization: Codable, Sendable {
        public var parameters: [String: String]?
        public var scheme: String?
    }
    public struct ServiceEndpoint: Codable, Sendable {
        public var name: String
        public var url: String
        public var authorization: EndpointAuthorization?
        public var data: [String: String]?
        public var isShared: Bool?
        public var isReady: Bool?
    }
    public struct Resources: Codable, Sendable {
        public var endpoints: [ServiceEndpoint]?
    }
    public struct WorkspaceOptions: Codable, Sendable {
        public var clean: String?
    }
    public struct MaskHint: Codable, Sendable {
        public var type: String
        public var value: String
    }

    public var messageType: String?
    public var plan: Plan
    public var timeline: TimelineReference?
    public var jobId: String
    public var jobDisplayName: String?
    public var jobName: String?
    public var jobContainer: TemplateToken?
    public var jobServiceContainers: TemplateToken?
    public var jobOutputs: TemplateToken?
    public var requestId: Int64?
    public var lockedUntil: String?
    public var resources: Resources?
    public var contextData: [String: ContextData]?
    public var workspace: WorkspaceOptions?
    public var maskHints: [MaskHint]?
    public var environmentVariables: [TemplateToken]?
    public var defaults: [TemplateToken]?
    public var actionsEnvironment: ActionsEnvironmentReference?
    public var variables: [String: VariableValue]?
    public var steps: [ActionStep]?
    public var fileTable: [String]?
    public var billingOwnerId: String?
    public var snapshot: JSONValue?

    enum CodingKeys: String, CodingKey {
        case messageType, plan, timeline, jobId, jobDisplayName, jobName, jobContainer, jobServiceContainers
        case jobOutputs, requestId, lockedUntil, resources, contextData, workspace
        case maskHints = "mask"
        case environmentVariables, defaults, actionsEnvironment, variables, steps, fileTable, billingOwnerId, snapshot
    }

    public func endpoint(named name: String) -> ServiceEndpoint? {
        resources?.endpoints?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var systemConnection: ServiceEndpoint? { endpoint(named: "SystemVssConnection") }

    public func variable(_ name: String) -> String? {
        variables?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.value
    }

    public func context(_ name: String) -> ContextData? {
        contextData?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ActionStep: Codable, Sendable {
    public struct Reference: Codable, Sendable {
        /// "repository" | "script" | "containerRegistry"
        public var type: String
        public var name: String?
        public var ref: String?
        public var repositoryType: String?
        public var path: String?
        public var image: String?
    }

    public var type: String?           // "action"
    public var id: String
    public var name: String?
    public var reference: Reference
    public var displayNameToken: TemplateToken?
    public var displayName: String?
    public var contextName: String?
    public var condition: String?
    public var continueOnError: TemplateToken?
    public var timeoutInMinutes: TemplateToken?
    public var inputs: TemplateToken?
    public var environment: TemplateToken?
}
