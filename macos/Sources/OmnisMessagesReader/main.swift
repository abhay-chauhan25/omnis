import Foundation
import MessagesReaderCore

// OMNIS Messages Reader. The one program that is given Full Disk Access, so
// that OMNIS itself, and everything OMNIS starts, does not need it.
//
// It reads the Messages database and nothing else, answers a fixed set of
// questions, writes nothing, and talks only to OMNIS as signed on this Mac.
// It takes no instructions from a model: only the few typed values in
// `ReaderRequest`. It stops by itself after two minutes with nothing to do.

signal(SIGPIPE, SIG_IGN)
let info = Bundle.main.infoDictionary ?? [:]
// Written into the bundle when it is built. Without it, nobody is answered.
guard let requirement = info["OMNISCallerRequirement"] as? String, requirement.contains("certificate leaf") else {
    FileHandle.standardError.write(Data("OMNIS Messages Reader was built without a caller to trust, so it will not run.\n".utf8))
    exit(2)
}
let home = FileManager.default.homeDirectoryForCurrentUser.path
let server = ReaderServer(
    socketPath: home + "/Library/Application Support/OMNIS/helper/messages.sock",
    databasePath: home + "/Library/Messages/chat.db",
    callerRequirement: requirement
)
exit(server.run() ? 0 : 1)
