import os,plistlib,re,shutil,subprocess
from pathlib import Path
root=Path(os.environ['ROOT']); out=root/'ThirdParty/StoreCores'; out.mkdir(parents=True,exist_ok=True)
# App Store rejects binaries stamped with a beta SDK, so device slices are stamped with the public SDK.
store_sdk=os.environ.get('STORE_SDK','27.0'); sim_sdk=os.environ.get('SIM_SDK','27.1')
cores={'AzaharCore':('AzaharCore.xcframework','azahar_libretro.dylib'),'MelonDSCore':('MelonDSCore.xcframework','melondsds_libretro.dylib'),'DeSmuMECore':('DeSmuMECore.xcframework','desmume_libretro_ios.dylib'),'N64Core':('N64Core.xcframework','parallel_n64_libretro_ios.dylib'),'PPSSPPCore':('PPSSPPCore.xcframework','ppsspp_libretro_ios.dylib')}

def stamp_build_version(binary,simulator):
 # Always -replace: without it vtool appends a second load command, and a simulator slice that also
 # claims platform iOS no longer links ("incompatible platforms: iOS-simulator - iOS").
 # Returns the binary's minimum OS so Info.plist MinimumOSVersion can match it (ITMS-90208).
 show=lambda: subprocess.run(['xcrun','vtool','-show-build',str(binary)],capture_output=True,text=True).stdout
 shown=show(); tmp=binary.with_name(binary.name+'.vtool')
 minos=re.search(r'minos\s+(\S+)',shown)
 if minos:
  platform,sdk=('iossim',sim_sdk) if simulator else ('ios',store_sdk)
  cmd=['-set-build-version',platform,minos.group(1),sdk]; minimum=minos.group(1)
 else:  # LC_VERSION_MIN_IPHONEOS binaries (DeSmuMECore device slice)
  minimum=re.search(r'version\s+(\S+)',shown).group(1)
  cmd=['-set-version-min','ios',minimum,sim_sdk if simulator else store_sdk]
 subprocess.run(['xcrun','vtool',*cmd,'-replace','-output',str(tmp),str(binary)],check=True,stdout=subprocess.DEVNULL)
 tmp.replace(binary)
 after=show()
 assert after.count('cmd LC_')<=1 or len(re.findall(r'(platform|version)\s',after))==1,(binary,after)
 if simulator: assert 'IOSSIMULATOR' in after and 'LC_VERSION_MIN' not in after,(binary,after)
 return minimum

for name,(xc,bn) in cores.items():
 src=root/'ThirdParty'/xc; st=root/'work'/(name+'-staged'); shutil.rmtree(st,ignore_errors=True); st.mkdir()
 args=['xcodebuild','-create-xcframework']
 for ident in ('ios-arm64','ios-arm64-simulator'):
  f=st/ident/(name+'.framework'); f.mkdir(parents=True); shutil.copy2(src/ident/bn,f/name)
  if (src/ident/'Headers').exists(): shutil.copytree(src/ident/'Headers',f/'Headers')
  info={'CFBundleExecutable':name,'CFBundleIdentifier':'com.duods.core.'+name.lower(),'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':name,'CFBundlePackageType':'FMWK','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','CFBundleSupportedPlatforms':['iPhoneOS' if ident=='ios-arm64' else 'iPhoneSimulator']}
  subprocess.run(['install_name_tool','-id',f'@rpath/{name}.framework/{name}',str(f/name)],check=True); subprocess.run(['codesign','--remove-signature',str(f/name)],check=False)
  info['MinimumOSVersion']=stamp_build_version(f/name,simulator=ident.endswith('simulator'))
  (f/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML))
  args += ['-framework',str(f)]
 args += ['-output',str(out/(name+'.xcframework'))]; subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
print(out)
