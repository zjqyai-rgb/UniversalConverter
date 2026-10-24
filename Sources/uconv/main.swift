import ConverterKit
import Foundation

// Command-line front end for the same engine the app uses.
//   uconv list <files…>              actions available for the files
//   uconv run <action-id> <files…>   perform an action
//   uconv actions                    every action id
//   uconv stats                      counts

let args = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    print("usage: uconv list <files…> | run <action-id> [-o dir] <files…> | actions | stats")
    exit(2)
}
guard let cmd = args.first else { usage() }

switch cmd {
case "actions":
    for a in ActionRegistry.all { print("\(a.id)\t\(a.category.rawValue)\t\(a.title) — \(a.detail)") }
case "stats":
    print("actions: \(ActionRegistry.all.count)")
    print("conversions (input format × action): \(ActionRegistry.conversionCount)")
case "list":
    let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
    for a in ActionRegistry.actions(for: urls) { print("\(a.id)\t\(a.title)") }
case "run":
    guard args.count >= 3, let action = ActionRegistry.action(id: args[1]) else { usage() }
    var rest = Array(args.dropFirst(2))
    var outDir: URL?
    if rest.first == "-o", rest.count >= 3 { outDir = URL(fileURLWithPath: rest[1]); rest.removeFirst(2) }
    let urls = rest.map { URL(fileURLWithPath: $0).standardizedFileURL }
    guard action.canHandle(urls) else {
        FileHandle.standardError.write(Data("\(action.id) can't handle these files\n".utf8)); exit(1)
    }
    let ctx = ActionContext(outputDirectory: outDir)
    do {
        let out = try await action.run(urls, context: ctx)
        for f in out.files { print(f.path) }
        if let m = out.message { print(m) }
        if let c = out.clipboard, out.message == nil { print(c) }
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
default:
    usage()
}
