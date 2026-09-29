import Foundation

// MARK: - Registration (api.github.com)

public struct RunnerRegistrationRequest: Encodable {
    public var url: String
    public var runnerEvent: String
    enum CodingKeys: String, CodingKey { case url; case runnerEvent = "runner_event" }
}

public struct RunnerRegistrationToken: Decodable {
    public var token: String
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey { case token; case expiresAt = "expires_at" }
}

/// Response of `POST /actions/runner-registration`.
public struct GitHubAuthResult: Codable, Sendable {
    public var url: String            // tenant (Actions service) URL
    public var token: String
    public var tokenSchema: String?
    public var useV2Flow: Bool?
    enum CodingKeys: String, CodingKey {
        case url, token
        case tokenSchema = "token_schema"
        case useV2Flow = "use_v2_flow"
    }
}

/// Response of `POST /actions/runners/register` (v2 flow).
public struct RunnerV2RegisterResponse: Decodable {
    public struct Authorization: Decodable {
        public var authorizationUrl: String
        public var serverUrl: String?
        public var clientId: String
        enum CodingKeys: String, CodingKey {
            case authorizationUrl = "authorization_url"
            case serverUrl = "server_url"
            case clientId = "client_id"
        }
    }
    public var id: Int64
    public var name: String
    public var authorization: Authorization
}

public struct RunnerGroupList: Decodable {
    public struct Group: Decodable {
        public var id: Int64
        public var name: String
        public var isDefault: Bool?
        public var isHosted: Bool?
        enum CodingKeys: String, CodingKey { case id, name; case isDefault = "default"; case isHosted = "is_hosted" }
    }
    public var runnerGroups: [Group]
    enum CodingKeys: String, CodingKey { case runnerGroups = "runner_groups" }
}

public struct RunnerList: Decodable {
    public struct Runner: Decodable { public var id: Int64; public var name: String }
    public var runners: [Runner]
}

// MARK: - Actions service (VSS) objects

public struct ServiceDefinition: Decodable, Sendable {
    public var serviceType: String
    public var identifier: String
    public var displayName: String
    public var relativeToSetting: String?
    public var relativePath: String
}

public struct ConnectionData: Decodable, Sendable {
    public struct LocationServiceData: Decodable, Sendable {
        public var serviceDefinitions: [ServiceDefinition]
    }
    public var locationServiceData: LocationServiceData
}

public struct AgentLabel: Codable, Sendable, Equatable {
    public var id: Int?
    public var name: String
    public var type: String  // "system" | "user"
    public init(name: String, type: String) { self.name = name; self.type = type }
}

public struct TaskAgentPublicKey: Codable, Sendable, Equatable {
    public var exponent: String
    public var modulus: String
}

public struct TaskAgentAuthorization: Codable, Sendable, Equatable {
    public var authorizationUrl: String?
    public var clientId: String?
    public var publicKey: TaskAgentPublicKey
}

/// `PropertiesCollection` values arrive as `{ "$type": "System.Boolean", "$value": true }`.
public struct PropertyValue: Codable, Sendable, Equatable {
    public var type: String?
    public var value: JSONValue
    enum CodingKeys: String, CodingKey { case type = "$type"; case value = "$value" }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.value) {
            type = try c.decodeIfPresent(String.self, forKey: .type)
            value = try c.decode(JSONValue.self, forKey: .value)
        } else {
            value = try JSONValue(from: decoder)
            switch value {
            case .bool: type = "System.Boolean"
            case .string: type = "System.String"
            default: type = nil
            }
        }
    }
}

public struct TaskAgent: Codable, Sendable, Equatable {
    public var id: Int64?
    public var name: String
    public var version: String
    public var osDescription: String
    public var ephemeral: Bool?
    public var disableUpdate: Bool?
    public var maxParallelism: Int?
    public var provisioningState: String?
    public var createdOn: String?
    public var labels: [AgentLabel]
    public var authorization: TaskAgentAuthorization
    public var properties: [String: PropertyValue]?

    public func property(_ name: String) -> JSONValue? {
        properties?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.value
    }

    public var serverUrlV2: String? {
        guard property("UseV2Flow")?.boolValue == true,
              let url = property("ServerUrlV2")?.stringValue, !url.isEmpty else { return nil }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    public var requireFipsCryptography: Bool {
        property("RequireFipsCryptography")?.boolValue == true
    }
}

public struct TaskAgentPool: Decodable, Sendable {
    public var id: Int64
    public var name: String
    public var isHosted: Bool?
    public var isInternal: Bool?
}

public struct VssList<T: Decodable>: Decodable {
    public var count: Int?
    public var value: [T]
}

public struct TaskAgentSessionKey: Codable, Sendable {
    public var encrypted: Bool
    public var value: String?
}

public struct BrokerMigration: Codable, Sendable {
    public var brokerBaseUrl: String
}

public struct TaskAgentSession: Codable, Sendable {
    public var sessionId: String?
    public var encryptionKey: TaskAgentSessionKey?
    public var ownerName: String?
    public var agent: TaskAgent?
    public var useFipsEncryption: Bool?
    public var brokerMigrationMessage: BrokerMigration?
    public var assignmentQueued: Bool?
    public var orchestrationId: String?
}

public struct TaskAgentMessage: Codable, Sendable {
    public var messageId: Int64?
    public var messageType: String
    public var iv: String?
    public var body: String?
}

public enum MessageType {
    public static let pipelineAgentJobRequest = "PipelineAgentJobRequest"
    public static let runnerJobRequest = "RunnerJobRequest"
    public static let jobCancellation = "JobCancellation"
    public static let runnerRefresh = "RunnerRefresh"
    public static let forceTokenRefresh = "ForceTokenRefresh"
    public static let brokerMigration = "BrokerMigration"
    public static let hostedRunnerShutdown = "HostedRunnerShutdown"
}

public struct JobCancellationMessage: Decodable, Sendable {
    public var jobId: String
    public var timeout: String?
}

/// Body of a broker `RunnerJobRequest` message: a pointer to the run service.
public struct RunnerJobRequestRef: Codable, Sendable {
    public var id: String?
    public var runnerRequestId: String?
    public var runServiceUrl: String?
    public var billingOwnerId: String?
    enum CodingKeys: String, CodingKey {
        case id
        case runnerRequestId = "runner_request_id"
        case runServiceUrl = "run_service_url"
        case billingOwnerId = "billing_owner_id"
    }
}

public struct OAuthTokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var expiresIn: Int?
    public var tokenType: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Job lifecycle

public struct VariableValue: Codable, Sendable, Equatable {
    public var value: String?
    public var isSecret: Bool?
    public init(value: String?, isSecret: Bool? = nil) { self.value = value; self.isSecret = isSecret }
}

public struct RenewAgentRequest: Encodable {
    public var requestId: Int64
}

public struct AcquireJobRequest: Encodable {
    public var streamId: String?
    public var jobMessageId: String
    public var billingOwnerId: String?
    public var runnerOS: String?
}

public struct RenewJobRequest: Encodable {
    public var planId: String
    public var jobId: String
}

public struct RenewJobResponse: Decodable {
    public var lockedUntil: String?
}

public struct Annotation: Codable, Sendable {
    public var level: String       // "FAILURE" | "WARNING" | "NOTICE" | "UNKNOWN"
    public var message: String
    public var path: String?
    public var startLine: Int64?
    public var endLine: Int64?
    public var startColumn: Int64?
    public var endColumn: Int64?
    public var stepNumber: Int64?
    public var rawDetails: String?
    // The run service (`completejob`) takes camelCase annotation fields.
}

public struct StepResultSummary: Codable, Sendable {
    public var externalId: String
    public var number: Int
    public var name: String
    public var status: String        // "completed" | "in_progress" | "pending"
    public var conclusion: String?   // "succeeded" | "failed" | "skipped" | "canceled"
    public var startedAt: String?
    public var completedAt: String?
    public var completedLogUrl: String?
    public var completedLogLines: Int64?
    public var annotations: [Annotation]?
    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case number, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case completedLogUrl = "completed_log_url"
        case completedLogLines = "completed_log_lines"
        case annotations
    }
}

public struct CompleteJobRequest: Encodable {
    public struct Telemetry: Encodable { public var message: String; public var type: String }
    public var planId: String
    public var jobId: String
    public var conclusion: String          // "succeeded" | "failed" | "canceled" | ...
    public var outputs: [String: VariableValue]?
    public var stepResults: [StepResultSummary]?
    public var annotations: [Annotation]?
    public var telemetry: [Telemetry]?
    public var environmentUrl: String?
    public var billingOwnerId: String?
}

public struct JobCompletedEvent: Encodable {
    public var name = "JobCompleted"
    public var jobId: String
    public var requestId: Int64
    public var result: String   // Succeeded | Failed | Canceled | Skipped | SucceededWithIssues | Abandoned
    public var outputs: [String: VariableValue]?
    public var actionsEnvironment: ActionsEnvironmentReference?
}

public struct ActionsEnvironmentReference: Codable, Sendable {
    public var name: String?
    public var url: String?
}

public struct TaskLogReference: Codable, Sendable {
    public var id: Int
    public var location: String?
}

public struct TaskLog: Codable, Sendable {
    public var id: Int?
    public var location: String?
    public var path: String?
    public var lineCount: Int64?
    public var createdOn: String?
    public var lastChangedOn: String?
}

public struct Issue: Codable, Sendable {
    public var type: String       // "error" | "warning" | "notice"
    public var category: String?
    public var message: String
    public var isInfrastructureIssue: Bool?
    public var data: [String: String]?
}

public struct TimelineRecord: Codable, Sendable {
    public var id: String
    public var parentId: String?
    public var type: String          // "Job" | "Task"
    public var name: String
    public var refName: String?
    public var startTime: String?
    public var finishTime: String?
    public var currentOperation: String?
    public var percentComplete: Int?
    public var state: String?        // "Pending" | "InProgress" | "Completed"
    public var result: String?       // "Succeeded" | "SucceededWithIssues" | "Failed" | "Canceled" | "Skipped" | "Abandoned"
    public var resultCode: String?
    public var changeId: Int?
    public var lastModified: String?
    public var workerName: String?
    public var order: Int?
    public var log: TaskLogReference?
    public var errorCount: Int?
    public var warningCount: Int?
    public var issues: [Issue]?
    public var location: String?
    public var attempt: Int?
    public var identifier: String?
    public var agentPlatform: String?
    public var variables: [String: VariableValue]?
}

public struct TimelineRecordsUpdate: Encodable {
    public var count: Int
    public var value: [TimelineRecord]
}

public struct TimelineRecordFeedLines: Encodable {
    public var count: Int
    public var value: [String]
    public var stepId: String
    public var startLine: Int64?
}

public struct ActionReference: Codable, Sendable {
    public var nameWithOwner: String
    public var ref: String
    public var path: String?
}

public struct ActionReferenceList: Encodable {
    public var actions: [ActionReference]
}

public struct ActionDownloadInfo: Decodable, Sendable {
    public struct Authentication: Decodable, Sendable {
        public var expiresAt: String?
        public var token: String
    }
    public var authentication: Authentication?
    public var nameWithOwner: String
    public var resolvedNameWithOwner: String?
    public var resolvedSha: String?
    public var tarballUrl: String?
    public var zipballUrl: String?
    public var ref: String?
}

public struct ActionDownloadInfoCollection: Decodable, Sendable {
    public var actions: [String: ActionDownloadInfo]
}

// MARK: - Results service (twirp)

public enum Results {
    public struct SignedURLRequest: Encodable {
        public var workflowRunBackendId: String
        public var workflowJobRunBackendId: String
        public var stepBackendId: String?
        enum CodingKeys: String, CodingKey {
            case workflowRunBackendId = "workflow_run_backend_id"
            case workflowJobRunBackendId = "workflow_job_run_backend_id"
            case stepBackendId = "step_backend_id"
        }
    }
    public struct SignedURLResponse: Decodable {
        public var logsUrl: String?
        public var summaryUrl: String?
        public var blobStorageType: String?
        public var softSizeLimit: JSONValue?
        enum CodingKeys: String, CodingKey {
            case logsUrl = "logs_url"
            case summaryUrl = "summary_url"
            case blobStorageType = "blob_storage_type"
            case softSizeLimit = "soft_size_limit"
        }
    }
    public struct LogsMetadata: Encodable {
        public var workflowRunBackendId: String
        public var workflowJobRunBackendId: String
        public var stepBackendId: String?
        public var uploadedAt: String
        public var lineCount: Int64?
        public var size: Int64?
        enum CodingKeys: String, CodingKey {
            case workflowRunBackendId = "workflow_run_backend_id"
            case workflowJobRunBackendId = "workflow_job_run_backend_id"
            case stepBackendId = "step_backend_id"
            case uploadedAt = "uploaded_at"
            case lineCount = "line_count"
            case size
        }
    }
    public struct Step: Encodable {
        public var externalId: String
        public var number: Int
        public var name: String
        public var status: Int        // 0 unknown, 3 in_progress, 5 pending, 6 completed
        public var startedAt: String?
        public var completedAt: String?
        public var conclusion: Int    // 0 unknown, 2 success, 3 failure, 4 cancelled, 7 skipped
        enum CodingKeys: String, CodingKey {
            case externalId = "external_id"
            case number, name, status
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case conclusion
        }
    }
    public struct StepsUpdateRequest: Encodable {
        public var steps: [Step]
        public var changeOrder: Int64
        public var workflowJobRunBackendId: String
        public var workflowRunBackendId: String
        enum CodingKeys: String, CodingKey {
            case steps
            case changeOrder = "change_order"
            case workflowJobRunBackendId = "workflow_job_run_backend_id"
            case workflowRunBackendId = "workflow_run_backend_id"
        }
    }
    public static let azureBlobStorage = "BLOB_STORAGE_TYPE_AZURE"
}
