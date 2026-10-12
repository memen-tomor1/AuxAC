import os
UU = lambda n: "%024X" % n
o = {}
def add(uid, body): o[uid] = body

add(UU(1), '{isa = PBXBuildFile; fileRef = %s; };' % UU(2))
add(UU(2), '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AuxACWidget.swift; sourceTree = "<group>"; };')
add(UU(3), '{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = AuxACWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; };')
add(UU(4), '{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AuxACWidget.entitlements; sourceTree = "<group>"; };')
add(UU(5), '{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };')
add(UU(6), '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };')
add(UU(7), '{isa = PBXGroup; children = (%s, %s, %s); path = AuxACWidget; sourceTree = "<group>"; };' % (UU(1).replace(UU(1),UU(2)), UU(4), UU(5)))
add(UU(8), '{isa = PBXGroup; children = (%s, %s); sourceTree = "<group>"; };' % (UU(7), UU(9)))
add(UU(9), '{isa = PBXGroup; children = (%s); name = Products; sourceTree = "<group>"; };' % UU(3))
add(UU(10), '{isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, %s, %s); buildRules = (); dependencies = (); name = AuxACWidget; productName = AuxACWidget; productReference = %s; productType = "com.apple.product-type.app-extension"; };' % (UU(11), UU(12), UU(6), UU(13), UU(3)))
add(UU(11), '{isa = XCConfigurationList; buildConfigurations = (%s, %s); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };' % (UU(14), UU(15)))
add(UU(12), '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0; };' % UU(1))
add(UU(13), '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };')

TARGET_COMMON = '''buildSettings = {
				ARCHS = arm64;
				CODE_SIGN_ENTITLEMENTS = AuxACWidget/AuxACWidget.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 0.1.0;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = AuxACWidget/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../../../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.local.auxac.AuxACWidget;
				PRODUCT_NAME = AuxACWidget;
				SDKROOT = macosx;
				SKIP_INSTALL = YES;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = %s; }'''
add(UU(14), '{isa = XCBuildConfiguration; ' + TARGET_COMMON % 'Debug')
add(UU(15), '{isa = XCBuildConfiguration; ' + TARGET_COMMON % 'Release')

PROJ = '''buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)");
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug; }'''
add(UU(16), '{isa = XCBuildConfiguration; ' + PROJ)
PROJ_R = PROJ.replace('DEBUG_INFORMATION_FORMAT = dwarf;', 'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";').replace('ENABLE_TESTABILITY = YES;','').replace('GCC_OPTIMIZATION_LEVEL = 0;','GCC_OPTIMIZATION_LEVEL = s;').replace('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";','SWIFT_COMPILATION_MODE = wholemodule;').replace('SWIFT_OPTIMIZATION_LEVEL = "-Onone";','SWIFT_OPTIMIZATION_LEVEL = "-O";').replace('name = Debug; }','name = Release; }')
add(UU(17), '{isa = XCBuildConfiguration; ' + PROJ_R)
add(UU(18), '{isa = XCConfigurationList; buildConfigurations = (%s, %s); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };' % (UU(16), UU(17)))

add(UU(19), '''{isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2650; LastUpgradeCheck = 2650; TargetAttributes = { %s = { CreatedOnToolsVersion = 26.5; }; }; }; buildConfigurationList = %s; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = %s; productRefGroup = %s; projectDirPath = ""; projectRoot = ""; minimizedProjectReferenceProxies = 1; preferredProjectObjectVersion = 77; targets = (%s); }''' % (UU(10), UU(18), UU(8), UU(9), UU(10)))

out = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 77;', '\tobjects = {']
for uid in sorted(o, key=lambda x: int(x, 16)):
    out.append('\t\t%s /* %s */ = %s;' % (uid, '', o[uid]))
out += ['\t};', '\trootObject = %s;' % UU(19), '}', '']
os.makedirs('AuxACWidget.xcodeproj', exist_ok=True)
open('AuxACWidget.xcodeproj/project.pbxproj','w').write('\n'.join(out))
print("pbxproj 生成完毕", len('\n'.join(out)), "字节")
