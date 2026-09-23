"""Run format and runtime checks on an isolated simulator; preserve the user's simulator."""
from pathlib import Path
import json, shutil, subprocess, sys
root=Path(__file__).resolve().parent.parent
sim='11625BCF-2BAF-4408-BCD3-76871FA635B6'
app=root/'.build/formats/Build/Products/Debug-iphonesimulator/DuoDS.app'
report=root/'RuntimeValidation/Formats'
def run(*args):return subprocess.check_output(['xcrun','simctl',*args],text=True).strip()
run('install',sim,str(app))
container=Path(run('get_app_container',sim,'com.duods.app','data'))
fixtures=container/'Documents/FormatChecks'
shutil.copytree(root/'TestFixtures/Formats',fixtures,dirs_exist_ok=True)
if (fixtures/'Results').exists():shutil.rmtree(fixtures/'Results')
try:
 with open(root/'.build/formats-latest.log','w') as log:
  subprocess.run(['xcrun','simctl','launch','--console-pty',sim,'com.duods.app','-interactiveTutorialCompleted.v2','YES','-format-test-root',str(fixtures)],stdout=log,stderr=subprocess.STDOUT,timeout=100,check=True)
except subprocess.TimeoutExpired:
 run('terminate',sim,'com.duods.app');print('FAIL: simulator runtime timed out');sys.exit(1)
result=fixtures/'Results/results.json'
if not result.exists():print('FAIL: app exited without a test report');sys.exit(1)
shutil.copytree(fixtures/'Results',report/'Results',dirs_exist_ok=True)
d=json.loads(result.read_text())
for k,v in d.items():print(k+': '+v)
sys.exit(any(v.startswith('FAIL') for v in d.values()))
