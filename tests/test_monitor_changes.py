from pathlib import Path
import subprocess
import tempfile
work = Path(tempfile.mkdtemp(prefix='aeropilot-monitor-tests-'))
s=(Path(__file__).resolve().parents[1] / 'AeroPilot.swift').read_text()
start=s.find('// BEGIN MonitorChangeObserver')
end=s.find('// END MonitorChangeObserver')
assert start >= 0 and end > start, 'FAIL: AeroPilot has no testable monitor-change observer; display changes never trigger reload'
harness=r'''
import AppKit
@main struct Test {
 @MainActor static func main() async {
  var signature = "odyssey"
  var reloads = 0
  let center = NotificationCenter()
  let watcher = MonitorChangeObserver(center: center, delay: 0.05,
   signature: { signature }, reload: { reloads += 1 })
  watcher.start()
  func event() { center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
  func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
  event(); await settle(); assert(reloads == 0, "unchanged displays must not reload")
  signature = "odyssey,lg"; event(); event(); event()
  await settle(); assert(reloads == 1, "hotplug burst must reload exactly once")
  signature = "odyssey"; event()
  await Task.yield()
  signature = "odyssey,lg"; event()
  await settle(); assert(reloads == 2, "disconnect/reconnect must reload even with same final set")
  watcher.start(); event(); await settle(); assert(reloads == 2, "start must be idempotent")
  signature = "lg,odyssey:new-origin"; event(); await settle()
  assert(reloads == 3, "geometry changes must reload")
  print("PASS: unchanged / burst / reconnect / repeated start / geometry")
 }
}
'''
p=work / 'Test.swift'
p.write_text(harness.split('@main')[0]+s[start:end]+'\n@main'+harness.split('@main')[1])
subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),'-o',str(work / 'test')],check=True)
subprocess.run([str(work / 'test')],check=True)
