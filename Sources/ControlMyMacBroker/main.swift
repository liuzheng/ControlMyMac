import ControlMyMacCore
import Foundation

let request = PrivilegedServiceHealthRequest(component: .broker)
let response = PrivilegedServiceHealth.respond(to: request, signing: .current())
let data = try JSONEncoder().encode(response)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
