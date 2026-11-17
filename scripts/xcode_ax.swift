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
//   xcode_ax wait <name> [secs]  wait until a button, row text or element named <name> exists
//   xcode_ax windows             Xcode's windows: index, capture|other, main|-, title (empty in the
//                                Performance view, so captures are recognized by their controls)
//   xcode_ax activate            bring Xcode to the front (positions only update while it's front)
//   xcode_ax raise <title|#i>    make the window titled <title> (or with index i) the main window
//   xcode_ax close <title|#i>    close that window
//   xcode_ax click <x> <y> [n]   a real mouse click (n = 2 for a double-click) at screen point x y
//   xcode_ax filter <text> [field]  type <text> into the Debug navigator's filter field (or the
//                                field described as [field]) and confirm
//   xcode_ax locate <text> --contains   like locate, but matches text containing <text>
//   xcode_ax select <text> [--contains]  select the row showing <text> (no mouse); rows have no AXPress
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
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"
let out = args.count > 2 ? args[2] : nil
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
if !AXIsProcessTrusted() { fail("no Accessibility permission for this process (System Settings > Privacy & Security > Accessibility)") }

func standardWindows() -> [AXUIElement] {
    ((attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { str($0, kAXSubroleAttribute) == "AXStandardWindow" }
}
func isCaptureWindow(_ w: AXUIElement) -> Bool {
    str(w, kAXTitleAttribute).hasSuffix(".gputrace") || find(w, { e in
        let r = str(e, kAXRoleAttribute)
        return (r == "AXButton" && (str(e, kAXTitleAttribute) == "Open Performance" || str(e, kAXTitleAttribute) == "Stop GPU workload"))
            || (r == "AXPopUpButton" && value(e) == "Performance")
    }) != nil
}

// Commands that don't need a window.
switch command {
case "activate":
    exit(app.activate() ? 0 : 1)
case "windows":
    // "<index>\t<capture|other>\t<main|->\t<title>" per standard window. A capture window is
    // recognized by its Metal debugger controls: in the Performance view its title is empty.
    for (i, w) in standardWindows().enumerated() {
        let main = (attr(w, kAXMainAttribute) as? Bool) == true ? "main" : "-"
        print("\(i)\t\(isCaptureWindow(w) ? "capture" : "other")\t\(main)\t\(str(w, kAXTitleAttribute))")
    }
    exit(0)
case "raise", "close":
    // raise <title | #index>: make that window the main one. close <...>: press its close button.
    let which = out ?? ""
    let all = standardWindows()
    let picked = which.hasPrefix("#") ? Int(which.dropFirst()).flatMap { $0 < all.count ? all[$0] : nil }
        : all.first(where: { str($0, kAXTitleAttribute) == which })
    guard let w = picked else { fail("no Xcode window \(which)") }
    if command == "raise" {
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        exit(AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success ? 0 : 1)
    }
    guard let button = attr(w, kAXCloseButtonAttribute) else { fail("window \(which) has no close button") }
    exit(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success ? 0 : 1)
case "click":
    guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { fail("usage: click <x> <y> [count]") }
    let n = args.count > 4 ? Int(args[4]) ?? 1 : 1
    let pt = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    for i in 1...max(1, n) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)!
            e.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        usleep(60_000)
    }
    exit(0)
default:
    break
}

// The main window, not a tooltip or popover, which also show up as windows.
let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let win = (attr(ax, kAXMainWindowAttribute) as! AXUIElement?)
    ?? windows.first(where: { str($0, kAXSubroleAttribute) == "AXStandardWindow" }) else {
    fail("no Xcode window")
}
func named(_ name: String) -> (AXUIElement) -> Bool {
    { e in
        str(e, kAXTitleAttribute) == name || str(e, kAXDescriptionAttribute) == name
            || (str(e, kAXRoleAttribute) == "AXStaticText" && value(e) == name)
    }
}

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
    let contains = args.contains("--contains")
    guard let hit = find(win, { e in
        str(e, kAXRoleAttribute) == "AXStaticText" && (contains ? value(e).contains(wanted) : value(e) == wanted)
    }) else {
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

case "select":
    // Select the outline/table row showing <text> through accessibility, without moving the mouse.
    let wanted = out ?? "", contains = args.contains("--contains")
    guard let hit = find(win, { e in
        str(e, kAXRoleAttribute) == "AXStaticText" && (contains ? value(e).contains(wanted) : value(e) == wanted)
    }) else { fail("no text \(wanted)") }
    var e = hit
    while str(e, kAXRoleAttribute) != "AXRow" {
        guard let parent = attr(e, kAXParentAttribute) else { fail("\(wanted) is not in a row") }
        e = parent as! AXUIElement
        if str(e, kAXRoleAttribute) == "AXWindow" { fail("\(wanted) is not in a row") }
    }
    exit(AXUIElementSetAttributeValue(e, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success ? 0 : 1)

case "wait":
    let name = out ?? "", secs = args.count > 3 ? Double(args[3]) ?? 30 : 30
    let deadline = Date().addingTimeInterval(secs)
    while Date() < deadline {
        let w = (attr(ax, kAXMainWindowAttribute) as! AXUIElement?) ?? win
        if find(w, named(name)) != nil { exit(0) }
        usleep(500_000)
    }
    fail("\(name) did not appear within \(Int(secs)) s")

case "filter":
    // The Debug navigator's field by default; the Performance view has its own
    // ("Filter the profiling timeline"), which a looser match would pick when the navigator is hidden.
    let text = out ?? "", fieldName = args.count > 3 ? args[3] : "Filter the trace list"
    guard let field = find(win, { e in
        let r = str(e, kAXRoleAttribute)
        return (r == "AXTextField" || r == "AXSearchField")
            && (str(e, kAXDescriptionAttribute) == fieldName || str(e, "AXPlaceholderValue") == fieldName)
    }) else { fail("no field \(fieldName): show the Debug navigator first (press Navigators)") }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
    AXUIElementPerformAction(field, kAXConfirmAction as CFString)
    for down in [true, false] {   // Return, which Xcode's filter fields listen for
        CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.postToPid(app.processIdentifier)
    }
    exit(0)

default:
    print("usage: xcode_ax tree [depth] | callstack [out] | shaders [out] | source <out> | locate <text> [--contains] | choose <shown> <item> | press <name> | wait <name> [secs] | windows | activate | raise <title> | close <title> | click <x> <y> [n] | filter <text> [field] | select <text> [--contains]")
}
