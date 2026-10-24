"""Keep the checked-in Xcode project usable without requiring XcodeGen on Windows."""
from pathlib import Path
import hashlib
import plistlib
ROOT=Path(__file__).resolve().parents[1]
project=ROOT/'ios/IPhoneAgent.xcodeproj/project.pbxproj'
text=project.read_text(encoding='utf-8')
files=[('ClickerProfile.swift','Board','IPhoneAgent'),('ClickerView.swift','UI','IPhoneAgent'),('ClickerTests.swift',None,'IPhoneAgentTests')]
for name,group,target in files:
    if f'/* {name} in Sources */' in text:
        continue
    def ident(s):return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
    ref,build=ident(name),ident(name+'build')
    text=text.replace('/* End PBXBuildFile section */',f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */')
    text=text.replace('/* End PBXFileReference section */',f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    import re
    groupname=group or target
    pattern=rf'(/\* {groupname} \*/ = \{{\s*isa = PBXGroup;\s*children = \()'
    text,n=re.subn(pattern,rf'\1\n\t\t\t\t{ref} /* {name} */,',text,count=1)
    if n!=1:raise RuntimeError('Missing group '+groupname)
    target_match=re.search(rf'/\* {target} \*/ = \{{\s*isa = PBXNativeTarget;.*?buildPhases = \(\s*([A-F0-9]+) /\* Sources \*/',text,re.S)
    if not target_match:raise RuntimeError('Missing target '+target)
    phase=target_match.group(1)
    pattern=rf'({phase} /\* Sources \*/ = \{{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = [0-9]+;\s*files = \()'
    text,n=re.subn(pattern,rf'\1\n\t\t\t\t{build} /* {name} in Sources */,',text,count=1)
    if n!=1:raise RuntimeError('Missing sources phase')
text=text.replace('TARGETED_DEVICE_FAMILY = 1;','TARGETED_DEVICE_FAMILY = "1,2";')
project.write_text(text,encoding='utf-8')
info=ROOT/'ios/IPhoneAgent/Info.plist'
with info.open('rb') as f:settings=plistlib.load(f)
settings['UIRequiresFullScreen']=False
settings['UISupportedInterfaceOrientations']=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']
settings['UISupportedInterfaceOrientations~ipad']=settings['UISupportedInterfaceOrientations']+['UIInterfaceOrientationPortraitUpsideDown']
with info.open('wb')as f:plistlib.dump(settings,f,sort_keys=False)
print('Updated Xcode project and iPad orientations.')
