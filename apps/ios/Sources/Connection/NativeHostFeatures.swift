import Foundation

struct NativeHostFeatures: Equatable {
    var agents = false
    var agentCreate = false
    var agentDelete = false
    var routines = false
    var routineHistory = false
    var reactions = false
    var notificationPreferences = false
    var browserView = false
    var browserSecretHandoff = false

    init(_ value: WireValue? = nil) {
        agents = value?["agents"]?.bool == true
        agentCreate = value?["agentCreate"]?.bool == true
        agentDelete = value?["agentDelete"]?.bool == true
        routines = value?["routines"]?.bool == true
        routineHistory = value?["routineHistory"]?.bool == true
        reactions = value?["reactions"]?.bool == true
        notificationPreferences = value?["notificationPreferences"]?.bool == true
        browserView = value?["browserView"]?.bool == true
        browserSecretHandoff = value?["browserSecretHandoff"]?.bool == true
    }
}
