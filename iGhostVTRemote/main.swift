import Darwin
import Dispatch
import Foundation

// `ighostvtd-remote`: remote access for one host. Spawned and supervised by
// `ighostvtd` (`RemoteSupervisor`) while the switch is on, with the
// management socket on descriptor 3. It listens on `RemoteAccess.port`,
// advertises the host over Bonjour, pairs new devices, and relays each
// paired device's requests to the daemon over a connection of its own —
// an XPC client like the app, never a part of the daemon.
//
// The network is reached by nothing else in this project, so nothing else
// runs as the user it lands on: on the device the daemon is root and this
// process drops to mobile before it opens a socket.

signal(SIGPIPE, SIG_IGN)

guard RemotePrivileges.dropToSessionUser() else {
    FileHandle.standardError.write(Data("ighostvtd-remote: could not drop privileges\n".utf8))
    exit(EXIT_FAILURE)
}

var descriptor = IOWire.socketDescriptor
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == IOWire.socketArgument, let value = arguments.popFirst().flatMap(Int32.init) {
        descriptor = value
    }
}

let service = RemoteService(managementDescriptor: descriptor)
service.start()
withExtendedLifetime(service) {
    dispatchMain()
}
