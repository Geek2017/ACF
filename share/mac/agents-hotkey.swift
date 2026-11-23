// agents-hotkey: one key, anywhere on a Mac, opens the fleet or brings its Terminal window forward
// (agents --window), as Meta+A does on Linux. _tools/mac-setup.sh builds it into ~/.local/bin and runs
// it at login as the launchd job io.github.acf.agents-hotkey.
//
//   agents-hotkey [KEY]     KEY: opt+a (the default), or e.g. ctrl+opt+a, cmd+shift+f
//
// Carbon's RegisterEventHotKey takes the key for this program alone and needs no Accessibility
// permission. While it runs, that key does nothing else anywhere (Option+A no longer types å).
import AppKit
import Carbon.HIToolbox

func say(_ s: String) { FileHandle.standardError.write(("agents-hotkey: " + s + "\n").data(using: .utf8)!) }

let keys: [String: Int] = [
  "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
  "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
  "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
  "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
  "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
  "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
  "space": kVK_Space, "return": kVK_Return, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
]

let spec = (CommandLine.arguments.dropFirst().first ?? "opt+a").lowercased()
var mods: UInt32 = 0
var code: Int? = nil
for part in spec.split(separator: "+").map(String.init) {
  switch part {
  case "cmd", "command": mods |= UInt32(cmdKey)
  case "opt", "option", "alt": mods |= UInt32(optionKey)
  case "ctrl", "control": mods |= UInt32(controlKey)
  case "shift": mods |= UInt32(shiftKey)
  default:
    guard let c = keys[part] else { say("no key called \(part) in \(spec)"); exit(0) }  // 0: launchd must not retry
    code = c
  }
}
guard let key = code, mods != 0 else { say("\(spec) needs a key and at least one of cmd, opt, ctrl, shift"); exit(0) }

var last = Date.distantPast
func openFleet() {
  if Date().timeIntervalSince(last) < 1 { return }   // a second press while the window is still coming up
  last = Date()
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  p.arguments = ["-lc", "exec \"$HOME/.local/bin/agents\" --window"]   // a login shell: Homebrew on PATH
  p.standardInput = FileHandle.nullDevice
  do { try p.run() } catch { say("could not run agents --window: \(error)") }
}

var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in openFleet(); return noErr }, 1, &pressed, nil, nil)
var ref: EventHotKeyRef?
let st = RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x4146_4321), id: 1),
                             GetApplicationEventTarget(), 0, &ref)
guard st == noErr else { say("\(spec) is taken by another program (\(st)): pick another, e.g. ACF_HOTKEY=ctrl+opt+a bash _tools/mac-setup.sh"); exit(0) }
say("\(spec) opens the fleet")
NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no menu bar
NSApplication.shared.run()
