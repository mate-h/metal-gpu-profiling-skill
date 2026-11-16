// Reads Xcode's Metal debugger through the macOS accessibility API, which is roughly 100x faster
// than osascript / System Events on Xcode's large UI tree.
//
// Build:  swiftc -O xcode_ax.swift -o xcode_ax
// Needs:  Accessibility permission for the terminal that runs it, and a .gputrace open in Xcode.
//
//   xcode_ax tree [depth]        print the front Xcode window's element tree (role | description | title | value)
//   xcode_ax callstack [out]     the shader source pane's Call Stack outline as an indented cost tree
//   xcode_ax shaders [out]       the Performance > Shaders table (cost, function, pipeline, registers, spills)
//   xcode_ax source <out>        the shader source text shown in the source pane
//   xcode_ax locate <text>       centre "x y" of the row (or element) showing <text>, for a
//                                CGEvent click; table rows have no AXPress
//   xcode_ax choose <shown> <item>  open the pop-up button showing <shown> and pick <item>, e.g.
//                                choose "Source Files" "Call Stack" in the shader source pane
//   xcode_ax press <name>        AXPress the first button whose title or description is <name>
//                                ("Open Performance", "Shaders", "Counters", ...)
//
// See references/xcode-gpu-debugger.md for how to get each view on screen.
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func value(_ e: AXUIElement) -> String {
    guard let v = attr(e, kAXValueAttribute) else { return "" }
    return String(describing: v)
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, depth: Int = 0, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    if depth > 30 { return nil }
    for k in kids(e) { if let f = find(k, depth: depth + 1, pred) { return f } }
    return nil
}
func texts(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
    if depth > 4 { return [] }
    let r = str(e, kAXRoleAttribute)
    let own = (r == "AXStaticText" || r == "AXTextField") ? [value(e)] : []
    return own + kids(e).flatMap { texts($0, depth + 1) }
}
func write(_ s: String, _ path: String?) {
    if let p = path { try! s.write(toFile: p, atomically: false, encoding: .utf8) } else { print(s, terminator: "") }
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first else {
    FileHandle.standardError.write("Xcode is not running\n".data(using: .utf8)!); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
// The main window, not a tooltip or popover, which also show up as windows.
let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let win = (attr(ax, kAXMainWindowAttribute) as! AXUIElement?)
    ?? windows.first(where: { str($0, kAXSubroleAttribute) == "AXStandardWindow" }) else {
    FileHandle.standardError.write("no Xcode window (is Accessibility permission granted?)\n".data(using: .utf8)!); exit(1)
}
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"
let out = args.count > 2 ? args[2] : nil

switch command {
case "tree":
    let maxDepth = args.count > 2 ? Int(args[2]) ?? 10 : 10
    func walk(_ e: AXUIElement, _ d: Int) {
        if d > maxDepth { return }
        let r = str(e, kAXRoleAttribute)
        var v = r == "AXTextArea" ? "<text>" : value(e)
        if v.count > 80 { v = String(v.prefix(80)) }
        print(String(repeating: "  ", count: d) + "\(r) | \(str(e, kAXDescriptionAttribute)) | \(str(e, kAXTitleAttribute)) | \(v)")
        for k in kids(e) { walk(k, d + 1) }
    }
    walk(win, 0)

case "callstack":
    // The outline whose first row is the entry point, once the source pane's popup shows Call Stack.
    guard let outline = find(win, { e in
        guard str(e, kAXRoleAttribute) == "AXOutline",
              let first = (attr(e, kAXRowsAttribute) as? [AXUIElement])?.first else { return false }
        return texts(first).contains { $0.hasSuffix("%") } && !texts(first).contains { $0.contains("_pass") }
    }) else {
        FileHandle.standardError.write("no Call Stack outline: open a shader and pick Call Stack in the source pane's popup\n".data(using: .utf8)!); exit(1)
    }
    var s = ""
    for row in (attr(outline, kAXRowsAttribute) as? [AXUIElement]) ?? [] {
        let t = texts(row).filter { !$0.isEmpty }
        let level = (attr(row, "AXDisclosureLevel") as? Int) ?? 0
        let cost = t.first { $0.hasSuffix("%") } ?? "-"
        let name = t.first { !$0.hasSuffix("%") } ?? "?"
        s += String(repeating: "  ", count: level) + cost + " " + name + "\n"
    }
    write(s, out)

case "shaders":
    guard let table = find(win, { e in
        str(e, kAXRoleAttribute) == "AXTable" &&
            kids(e).contains { g in kids(g).contains { str($0, kAXTitleAttribute) == "# Allocated Registers" } }
    }) else {
        FileHandle.standardError.write("no Shaders table: open Performance > Shaders\n".data(using: .utf8)!); exit(1)
    }
    var s = "cost\tfunction\ttype\tpipeline\tsimd_groups\tallocated_registers\thigh_register\tspilled\n"
    func rows(_ e: AXUIElement) -> [AXUIElement] {
        str(e, kAXRoleAttribute) == "AXRow" ? [e] : kids(e).flatMap(rows)
    }
    for row in rows(table) { s += texts(row).joined(separator: "\t") + "\n" }
    write(s, out)

case "source":
    guard let text = find(win, { str($0, kAXRoleAttribute) == "AXTextArea" && str($0, kAXDescriptionAttribute) == "Source Editor" }) else {
        FileHandle.standardError.write("no source editor open\n".data(using: .utf8)!); exit(1)
    }
    write(value(text), out ?? "/dev/stdout")

case "locate":
    let wanted = out ?? ""
    guard let hit = find(win, { str($0, kAXRoleAttribute) == "AXStaticText" && value($0) == wanted }) else {
        FileHandle.standardError.write("no text \(wanted)\n".data(using: .utf8)!); exit(1)
    }
    var e = hit
    while str(e, kAXRoleAttribute) != "AXRow", let parent = attr(e, kAXParentAttribute) {
        e = parent as! AXUIElement
        if str(e, kAXRoleAttribute) == "AXWindow" { e = hit; break }
    }
    var p = CGPoint.zero, z = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &z) }
    // Rows can be wider than the screen: aim near their left edge.
    print(Int(p.x + min(z.width / 2, 200)), Int(p.y + z.height / 2))

case "choose":
    let shown = out ?? "", item = args.count > 3 ? args[3] : ""
    guard let popup = find(win, { str($0, kAXRoleAttribute) == "AXPopUpButton" && value($0) == shown }) else {
        FileHandle.standardError.write("no pop-up showing \(shown)\n".data(using: .utf8)!); exit(1)
    }
    AXUIElementPerformAction(popup, kAXPressAction as CFString)
    usleep(400_000)
    guard let entry = find(popup, { str($0, kAXRoleAttribute) == "AXMenuItem" && str($0, kAXTitleAttribute) == item }) else {
        AXUIElementPerformAction(popup, kAXCancelAction as CFString)
        FileHandle.standardError.write("no item \(item)\n".data(using: .utf8)!); exit(1)
    }
    exit(AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success ? 0 : 1)

case "press":
    let name = out ?? ""
    guard let button = find(win, { e in
        let r = str(e, kAXRoleAttribute)
        return (r == "AXButton" || r == "AXRadioButton" || r == "AXMenuButton")
            && (str(e, kAXTitleAttribute) == name || str(e, kAXDescriptionAttribute) == name)
    }) else {
        FileHandle.standardError.write("no button named \(name)\n".data(using: .utf8)!); exit(1)
    }
    exit(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? 0 : 1)

default:
    print("usage: xcode_ax tree [depth] | callstack [out] | shaders [out] | source <out> | locate <text> | choose <shown> <item> | press <name>")
}
