import ControlMyMacCore
import Foundation

// This health-only executable intentionally performs no ServiceManagement,
// Authorization Services, socket, process, or network operation. It exists to
// validate target signing and protocol compatibility before root registration.
let request = PrivilegedServiceHealthRequest(component: .helper)
let response = PrivilegedServiceHealth.respond(to: request, signing: .current())
let data = try JSONEncoder().encode(response)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
