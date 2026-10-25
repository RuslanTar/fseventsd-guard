// fsprobe: does fseventsd still deliver events? Runs as the user, no root.
//
//   fsprobe <dir> [timeout_s]
//
// Watches <dir> with an FSEvents stream, writes one uniquely named file into it and
// times how long the event for that file takes to arrive.
//   exit 0, prints "result=ok latency_ms=N start_ms=S eid=E"     the event arrived
//   exit 2, prints "result=stalled timeout_s=N start_ms=S eid=E" no event within the timeout
//   exit 3, prints "result=error ..."                            the probe itself could not run
// start_ms is how long FSEventStreamStart took (a healthy daemon: 0-1 ms); eid is
// FSEventsGetCurrentEventId() right after it, so callers can rate events between
// probes. A stalled line has neither when the start itself had not returned by the
// timeout.
//
// A watchdog on a separate queue enforces the timeout even if the FSEvents calls
// block inside a wedged daemon. Built by `fseventsd-guard install` with swiftc.
// Based on the stream setup of the fsrank measurement tool.
import Foundation
import CoreServices

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("result=error usage: fsprobe <dir> [timeout_s]")
    exit(3)
}
let timeout = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
let fm = FileManager.default
do {
    try fm.createDirectory(atPath: args[1], withIntermediateDirectories: true)
} catch {
    print("result=error cannot create \(args[1]): \(error.localizedDescription)")
    exit(3)
}
// FSEvents reports real paths (/private/var, not /var); watch and match on those.
let dir = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().path
let name = "probe-\(getpid())-\(UInt64(Date().timeIntervalSince1970 * 1000))"
let target = dir + "/" + name

func cleanup() { try? fm.removeItem(atPath: target) }

var startMs: Int? = nil
var eventId: UInt64? = nil
func startField() -> String { (startMs.map { " start_ms=\($0)" } ?? "") + (eventId.map { " eid=\($0)" } ?? "") }

DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
    cleanup()
    print(String(format: "result=stalled timeout_s=%.0f", timeout) + startField())
    exit(2)
}

var written: Date? = nil
let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
    let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    for i in 0..<min(count, list.count) where list[i] == target || list[i].hasSuffix("/" + name) {
        let ms = Int((Date().timeIntervalSince(written ?? Date())) * 1000)
        cleanup()
        print("result=ok latency_ms=\(ms)" + startField())
        exit(0)
    }
}

let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
guard let stream = FSEventStreamCreate(nil, callback, nil, [dir] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
    print("result=error FSEventStreamCreate failed")
    exit(3)
}
let queue = DispatchQueue(label: "fsprobe.events")
FSEventStreamSetDispatchQueue(stream, queue)
let startBegan = DispatchTime.now().uptimeNanoseconds
let started = FSEventStreamStart(stream)
startMs = Int((DispatchTime.now().uptimeNanoseconds - startBegan) / 1_000_000)
guard started else {
    print("result=error FSEventStreamStart failed")
    exit(3)
}
eventId = FSEventsGetCurrentEventId()
// Give the stream a moment to attach before the write.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    queue.sync { written = Date() }
    guard fm.createFile(atPath: target, contents: Data("fsprobe\n".utf8)) else {
        print("result=error cannot write \(target)")
        exit(3)
    }
}
dispatchMain()
