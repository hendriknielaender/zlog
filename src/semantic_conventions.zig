const std = @import("std");
const field = @import("field.zig");

/// OpenTelemetry Semantic Conventions for common attributes
/// Based on: https://opentelemetry.io/docs/specs/semconv/
pub const SemanticConventions = struct {

    // Service attributes
    pub const SERVICE_NAME = "service.name";
    pub const SERVICE_VERSION = "service.version";
    pub const SERVICE_NAMESPACE = "service.namespace";
    pub const SERVICE_INSTANCE_ID = "service.instance.id";

    // Process attributes
    pub const PROCESS_PID = "process.pid";
    pub const PROCESS_EXECUTABLE_NAME = "process.executable.name";
    pub const PROCESS_EXECUTABLE_PATH = "process.executable.path";
    pub const PROCESS_COMMAND_LINE = "process.command_line";
    pub const PROCESS_RUNTIME_NAME = "process.runtime.name";
    pub const PROCESS_RUNTIME_VERSION = "process.runtime.version";
    pub const PROCESS_RUNTIME_DESCRIPTION = "process.runtime.description";

    // Host attributes
    pub const HOST_ID = "host.id";
    pub const HOST_NAME = "host.name";
    pub const HOST_TYPE = "host.type";
    pub const HOST_ARCH = "host.arch";
    pub const HOST_IMAGE_NAME = "host.image.name";
    pub const HOST_IMAGE_ID = "host.image.id";
    pub const HOST_IMAGE_VERSION = "host.image.version";

    // OS attributes
    pub const OS_TYPE = "os.type";
    pub const OS_DESCRIPTION = "os.description";
    pub const OS_NAME = "os.name";
    pub const OS_VERSION = "os.version";

    // Container attributes
    pub const CONTAINER_NAME = "container.name";
    pub const CONTAINER_ID = "container.id";
    pub const CONTAINER_RUNTIME = "container.runtime";
    pub const CONTAINER_IMAGE_NAME = "container.image.name";
    pub const CONTAINER_IMAGE_TAG = "container.image.tag";

    // Kubernetes attributes
    pub const K8S_CLUSTER_NAME = "k8s.cluster.name";
    pub const K8S_NAMESPACE_NAME = "k8s.namespace.name";
    pub const K8S_POD_NAME = "k8s.pod.name";
    pub const K8S_POD_UID = "k8s.pod.uid";
    pub const K8S_DEPLOYMENT_NAME = "k8s.deployment.name";
    pub const K8S_REPLICASET_NAME = "k8s.replicaset.name";
    pub const K8S_NODE_NAME = "k8s.node.name";

    // Cloud attributes
    pub const CLOUD_PROVIDER = "cloud.provider";
    pub const CLOUD_ACCOUNT_ID = "cloud.account.id";
    pub const CLOUD_REGION = "cloud.region";
    pub const CLOUD_AVAILABILITY_ZONE = "cloud.availability_zone";
    pub const CLOUD_PLATFORM = "cloud.platform";

    // HTTP attributes
    pub const HTTP_METHOD = "http.method";
    pub const HTTP_URL = "http.url";
    pub const HTTP_STATUS_CODE = "http.status_code";
    pub const HTTP_USER_AGENT = "http.user_agent";
    pub const HTTP_REQUEST_SIZE = "http.request.size";
    pub const HTTP_RESPONSE_SIZE = "http.response.size";

    // Database attributes
    pub const DB_SYSTEM = "db.system";
    pub const DB_CONNECTION_STRING = "db.connection_string";
    pub const DB_USER = "db.user";
    pub const DB_NAME = "db.name";
    pub const DB_STATEMENT = "db.statement";
    pub const DB_OPERATION = "db.operation";

    // Messaging attributes
    pub const MESSAGING_SYSTEM = "messaging.system";
    pub const MESSAGING_DESTINATION = "messaging.destination";
    pub const MESSAGING_DESTINATION_KIND = "messaging.destination_kind";
    pub const MESSAGING_PROTOCOL = "messaging.protocol";
    pub const MESSAGING_URL = "messaging.url";

    // Error attributes
    pub const ERROR_TYPE = "error.type";
    pub const ERROR_MESSAGE = "error.message";
    pub const EXCEPTION_TYPE = "exception.type";
    pub const EXCEPTION_MESSAGE = "exception.message";
    pub const EXCEPTION_STACKTRACE = "exception.stacktrace";

    // User attributes
    pub const USER_ID = "user.id";
    pub const USER_NAME = "user.name";
    pub const USER_EMAIL = "user.email";
    pub const USER_ROLES = "user.roles";

    // Session attributes
    pub const SESSION_ID = "session.id";
    pub const SESSION_PREVIOUS_ID = "session.previous_id";

    // Network attributes
    pub const NET_PEER_NAME = "net.peer.name";
    pub const NET_PEER_IP = "net.peer.ip";
    pub const NET_PEER_PORT = "net.peer.port";
    pub const NET_HOST_NAME = "net.host.name";
    pub const NET_HOST_IP = "net.host.ip";
    pub const NET_HOST_PORT = "net.host.port";

    // Thread attributes
    pub const THREAD_ID = "thread.id";
    pub const THREAD_NAME = "thread.name";

    // Code attributes
    pub const CODE_FUNCTION = "code.function";
    pub const CODE_NAMESPACE = "code.namespace";
    pub const CODE_FILEPATH = "code.filepath";
    pub const CODE_LINENO = "code.lineno";
    pub const CODE_COLUMN = "code.column";
};

/// Helper functions to create semantic convention fields
pub const OTel = struct {

    // Service fields
    pub fn serviceName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.SERVICE_NAME, name);
    }

    pub fn serviceVersion(version: []const u8) field.Field {
        return field.Field.string(SemanticConventions.SERVICE_VERSION, version);
    }

    pub fn serviceNamespace(namespace: []const u8) field.Field {
        return field.Field.string(SemanticConventions.SERVICE_NAMESPACE, namespace);
    }

    pub fn serviceInstanceId(instance_id: []const u8) field.Field {
        return field.Field.string(SemanticConventions.SERVICE_INSTANCE_ID, instance_id);
    }

    // Process fields
    pub fn processPid(pid: u32) field.Field {
        return field.Field.uint(SemanticConventions.PROCESS_PID, pid);
    }

    pub fn processExecutableName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.PROCESS_EXECUTABLE_NAME, name);
    }

    pub fn processRuntimeName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.PROCESS_RUNTIME_NAME, name);
    }

    pub fn processRuntimeVersion(version: []const u8) field.Field {
        return field.Field.string(SemanticConventions.PROCESS_RUNTIME_VERSION, version);
    }

    // Host fields
    pub fn hostName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HOST_NAME, name);
    }

    pub fn hostArch(arch: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HOST_ARCH, arch);
    }

    pub fn hostType(host_type: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HOST_TYPE, host_type);
    }

    // OS fields
    pub fn osType(os_type: []const u8) field.Field {
        return field.Field.string(SemanticConventions.OS_TYPE, os_type);
    }

    pub fn osName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.OS_NAME, name);
    }

    pub fn osVersion(version: []const u8) field.Field {
        return field.Field.string(SemanticConventions.OS_VERSION, version);
    }

    // HTTP fields
    pub fn httpMethod(method: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HTTP_METHOD, method);
    }

    pub fn httpUrl(url: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HTTP_URL, url);
    }

    pub fn httpStatusCode(status_code: u16) field.Field {
        return field.Field.uint(SemanticConventions.HTTP_STATUS_CODE, status_code);
    }

    pub fn httpUserAgent(user_agent: []const u8) field.Field {
        return field.Field.string(SemanticConventions.HTTP_USER_AGENT, user_agent);
    }

    // Database fields
    pub fn dbSystem(system: []const u8) field.Field {
        return field.Field.string(SemanticConventions.DB_SYSTEM, system);
    }

    pub fn dbName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.DB_NAME, name);
    }

    pub fn dbStatement(statement: []const u8) field.Field {
        return field.Field.string(SemanticConventions.DB_STATEMENT, statement);
    }

    pub fn dbOperation(operation: []const u8) field.Field {
        return field.Field.string(SemanticConventions.DB_OPERATION, operation);
    }

    // Error fields
    pub fn errorType(error_type: []const u8) field.Field {
        return field.Field.string(SemanticConventions.ERROR_TYPE, error_type);
    }

    pub fn errorMessage(message: []const u8) field.Field {
        return field.Field.string(SemanticConventions.ERROR_MESSAGE, message);
    }

    pub fn exceptionType(exception_type: []const u8) field.Field {
        return field.Field.string(SemanticConventions.EXCEPTION_TYPE, exception_type);
    }

    pub fn exceptionMessage(message: []const u8) field.Field {
        return field.Field.string(SemanticConventions.EXCEPTION_MESSAGE, message);
    }

    pub fn exceptionStacktrace(stacktrace: []const u8) field.Field {
        return field.Field.string(SemanticConventions.EXCEPTION_STACKTRACE, stacktrace);
    }

    // User fields
    pub fn userId(user_id: []const u8) field.Field {
        return field.Field.string(SemanticConventions.USER_ID, user_id);
    }

    pub fn userName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.USER_NAME, name);
    }

    pub fn userEmail(email: []const u8) field.Field {
        return field.Field.string(SemanticConventions.USER_EMAIL, email);
    }

    // Session fields
    pub fn sessionId(session_id: []const u8) field.Field {
        return field.Field.string(SemanticConventions.SESSION_ID, session_id);
    }

    // Network fields
    pub fn netPeerName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.NET_PEER_NAME, name);
    }

    pub fn netPeerIp(ip: []const u8) field.Field {
        return field.Field.string(SemanticConventions.NET_PEER_IP, ip);
    }

    pub fn netPeerPort(port: u16) field.Field {
        return field.Field.uint(SemanticConventions.NET_PEER_PORT, port);
    }

    // Thread fields
    pub fn threadId(thread_id: u32) field.Field {
        return field.Field.uint(SemanticConventions.THREAD_ID, thread_id);
    }

    pub fn threadName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.THREAD_NAME, name);
    }

    // Code fields
    pub fn codeFunction(function: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CODE_FUNCTION, function);
    }

    pub fn codeNamespace(namespace: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CODE_NAMESPACE, namespace);
    }

    pub fn codeFilepath(filepath: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CODE_FILEPATH, filepath);
    }

    pub fn codeLineno(line_no: u32) field.Field {
        return field.Field.uint(SemanticConventions.CODE_LINENO, line_no);
    }

    // Kubernetes fields
    pub fn k8sClusterName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.K8S_CLUSTER_NAME, name);
    }

    pub fn k8sNamespaceName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.K8S_NAMESPACE_NAME, name);
    }

    pub fn k8sPodName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.K8S_POD_NAME, name);
    }

    pub fn k8sPodUid(uid: []const u8) field.Field {
        return field.Field.string(SemanticConventions.K8S_POD_UID, uid);
    }

    pub fn k8sDeploymentName(name: []const u8) field.Field {
        return field.Field.string(SemanticConventions.K8S_DEPLOYMENT_NAME, name);
    }

    // Cloud fields
    pub fn cloudProvider(provider: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CLOUD_PROVIDER, provider);
    }

    pub fn cloudRegion(region: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CLOUD_REGION, region);
    }

    pub fn cloudAccountId(account_id: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CLOUD_ACCOUNT_ID, account_id);
    }

    pub fn cloudPlatform(platform: []const u8) field.Field {
        return field.Field.string(SemanticConventions.CLOUD_PLATFORM, platform);
    }
};

/// Common field combinations for typical use cases
pub const CommonFields = struct {
    /// HTTP request logging fields
    pub fn httpRequest(method: []const u8, url: []const u8, status_code: u16, user_agent: ?[]const u8) [4]field.Field {
        return [_]field.Field{
            OTel.httpMethod(method),
            OTel.httpUrl(url),
            OTel.httpStatusCode(status_code),
            if (user_agent) |ua| OTel.httpUserAgent(ua) else field.Field.null_value(SemanticConventions.HTTP_USER_AGENT),
        };
    }

    /// Database operation logging fields
    pub fn dbOperation(system: []const u8, name: []const u8, operation: []const u8, statement: ?[]const u8) [4]field.Field {
        return [_]field.Field{
            OTel.dbSystem(system),
            OTel.dbName(name),
            OTel.dbOperation(operation),
            if (statement) |stmt| OTel.dbStatement(stmt) else field.Field.null_value(SemanticConventions.DB_STATEMENT),
        };
    }

    /// Error logging fields
    pub fn errorInfo(error_type: []const u8, message: []const u8, stacktrace: ?[]const u8) [3]field.Field {
        return [_]field.Field{
            OTel.errorType(error_type),
            OTel.errorMessage(message),
            if (stacktrace) |st| OTel.exceptionStacktrace(st) else field.Field.null_value(SemanticConventions.EXCEPTION_STACKTRACE),
        };
    }

    /// User context fields
    pub fn userContext(user_id: []const u8, name: ?[]const u8, email: ?[]const u8) [3]field.Field {
        return [_]field.Field{
            OTel.userId(user_id),
            if (name) |n| OTel.userName(n) else field.Field.null_value(SemanticConventions.USER_NAME),
            if (email) |e| OTel.userEmail(e) else field.Field.null_value(SemanticConventions.USER_EMAIL),
        };
    }
};

const testing = std.testing;

test "Semantic convention field creation" {
    const service_field = OTel.serviceName("my-service");
    try testing.expectEqualStrings(SemanticConventions.SERVICE_NAME, service_field.key);
    try testing.expectEqualStrings("my-service", service_field.value.string);

    const pid_field = OTel.processPid(12345);
    try testing.expectEqualStrings(SemanticConventions.PROCESS_PID, pid_field.key);
    try testing.expect(pid_field.value.uint == 12345);

    const status_field = OTel.httpStatusCode(200);
    try testing.expectEqualStrings(SemanticConventions.HTTP_STATUS_CODE, status_field.key);
    try testing.expect(status_field.value.uint == 200);
}

test "Common field combinations" {
    const http_fields = CommonFields.httpRequest("GET", "/api/users", 200, "Mozilla/5.0");
    try testing.expect(http_fields.len == 4);
    try testing.expectEqualStrings("GET", http_fields[0].value.string);
    try testing.expectEqualStrings("/api/users", http_fields[1].value.string);
    try testing.expect(http_fields[2].value.uint == 200);
    try testing.expectEqualStrings("Mozilla/5.0", http_fields[3].value.string);

    const db_fields = CommonFields.dbOperation("postgresql", "users_db", "SELECT", "SELECT * FROM users");
    try testing.expect(db_fields.len == 4);
    try testing.expectEqualStrings("postgresql", db_fields[0].value.string);
    try testing.expectEqualStrings("users_db", db_fields[1].value.string);
    try testing.expectEqualStrings("SELECT", db_fields[2].value.string);
    try testing.expectEqualStrings("SELECT * FROM users", db_fields[3].value.string);

    const error_fields = CommonFields.errorInfo("DatabaseError", "Connection timeout", null);
    try testing.expect(error_fields.len == 3);
    try testing.expectEqualStrings("DatabaseError", error_fields[0].value.string);
    try testing.expectEqualStrings("Connection timeout", error_fields[1].value.string);
    try testing.expect(error_fields[2].value == .null);
}

test "Semantic convention constants" {
    try testing.expectEqualStrings("service.name", SemanticConventions.SERVICE_NAME);
    try testing.expectEqualStrings("http.method", SemanticConventions.HTTP_METHOD);
    try testing.expectEqualStrings("db.system", SemanticConventions.DB_SYSTEM);
    try testing.expectEqualStrings("error.type", SemanticConventions.ERROR_TYPE);
    try testing.expectEqualStrings("user.id", SemanticConventions.USER_ID);
}
