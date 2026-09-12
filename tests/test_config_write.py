from pathlib import Path
import subprocess,tempfile
s=(Path(__file__).resolve().parents[1]/'AeroPilot.swift').read_text()
a=s.find('// BEGIN ConfigFile');b=s.find('// END ConfigFile')
assert a>=0 and b>a, 'Missing symlink-safe ConfigFile transaction'
with tempfile.TemporaryDirectory() as d:
 p=Path(d);src=p/'test.swift'
 src.write_text('import Foundation\n'+s[a:b]+r'''
let dir=URL(fileURLWithPath:CommandLine.arguments[1])
let original=dir.appendingPathComponent("repo.toml")
let live=dir.appendingPathComponent("live.toml")
try "# comment\nvalid".write(to:original,atomically:true,encoding:.utf8)
try FileManager.default.createSymbolicLink(at:live,withDestinationURL:original)
try ConfigFile.save("# comment\nnew", path:live.path) { true }
assert((try? String(contentsOf:original,encoding:.utf8))=="# comment\nnew")
assert((try? FileManager.default.destinationOfSymbolicLink(atPath:live.path))==original.path)
do {try ConfigFile.save("bad",path:live.path){false};fatalError("accepted invalid config") } catch {}
assert((try? String(contentsOf:original,encoding:.utf8))=="# comment\nnew")
print("PASS: symlink survives valid save and validation rollback")
''')
 subprocess.run(['xcrun','swiftc',str(src),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),d],check=True)
