"""A compiler failure must never reach stop/replace of an existing installation."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as d:
 p=Path(d);source=p/'source';source.mkdir()
 shutil.copy(root/'build.sh',source/'build.sh')
 (source/'AeroPilot.swift').write_text('this is deliberately invalid Swift')
 app=p/'Applications/AeroPilot.app';app.mkdir(parents=True)
 (app/'sentinel').write_text('installed version')
 result=subprocess.run(['bash',str(source/'build.sh'),'--no-run'],env={**os.environ,'HOME':d},capture_output=True,text=True,timeout=30)
 assert result.returncode != 0, 'invalid source unexpectedly built'
 assert (app/'sentinel').read_text()=='installed version', 'existing app was modified before compile succeeded'
 assert not list((p/'Applications').glob('.aeropilot-build.*')), 'staging directory leaked'
 print('PASS: compiler failure preserves installation and cleans staging')
