#!/usr/bin/env python3
# Regenerates HCGTerminal.xcodeproj (two app targets sharing the HCGTerminal/ folder).
# Usage: Scripts/generate-xcodeproj.py <repository root>
import os, sys
root = sys.argv[1]
n = [0]
def oid():
    n[0] += 1
    return "4C48%020X" % n[0]

PROJECT, MAINGROUP, PRODUCTS, SYNC, PKGREF = oid(), oid(), oid(), oid(), oid()
targets = [
    dict(name="HCGTerminal", display="HCG Terminal", bundle="com.hakmicapitalgroup.hcgterminal",
         ent="HCGTerminal-Support/HCGTerminal.entitlements", cond="$(inherited)",
         products=["TerminalUI", "FileWorkspace"]),
    dict(name="HCGTerminalUnleashed", display="HCG Terminal Unleashed", bundle="com.hakmicapitalgroup.hcgterminal.unleashed",
         ent="HCGTerminal-Support/HCGTerminalUnleashed.entitlements", cond="HCG_UNLEASHED_BUILD $(inherited)",
         products=["TerminalUI", "FileWorkspace", "UnleashedIntegration"]),
]
for t in targets:
    for k in ["target", "app", "sources", "frameworks", "resources", "cfglist", "debug", "release"]:
        t[k] = oid()
    t["deps"] = [(p, oid(), oid()) for p in t["products"]]  # (product, productRef, buildFile)
PROJ_CFGLIST, PROJ_DEBUG, PROJ_RELEASE = oid(), oid(), oid()

common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				SDKROOT = iphoneos;
"""
def proj_cfg(id_, name):
    extra = """				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
""" if name == "Debug" else """				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
"""
    return f"""		{id_} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}{extra}			}};
			name = {name};
		}};
"""
def target_cfg(t, id_, name):
    return f"""		{id_} /* {name} */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = {t['ent']};
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = "HCGTerminal-Support/Info.plist";
				INFOPLIST_KEY_CFBundleDisplayName = "{t['display']}";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UIStatusBarStyle = UIStatusBarStyleLightContent;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {t['bundle']};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{t['cond'] if name == 'Release' else 'DEBUG ' + t['cond']}";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = {name};
		}};
"""

out = []
w = out.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n")
w("/* Begin PBXBuildFile section */\n")
for t in targets:
    for p, ref, bf in t["deps"]:
        w(f"\t\t{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {ref} /* {p} */; }};\n")
w("/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n")
for t in targets:
    w(f"\t\t{t['app']} /* {t['name']}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {t['name']}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w("/* End PBXFileReference section */\n\n/* Begin PBXFileSystemSynchronizedRootGroup section */\n")
w(f"\t\t{SYNC} /* HCGTerminal */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = HCGTerminal;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXFileSystemSynchronizedRootGroup section */\n\n/* Begin PBXFrameworksBuildPhase section */\n")
for t in targets:
    files = "".join(f"\t\t\t\t{bf} /* {p} in Frameworks */,\n" for p, ref, bf in t["deps"])
    w(f"\t\t{t['frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n")
w(f"\t\t{MAINGROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{SYNC} /* HCGTerminal */,\n\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
apps = "".join(f"\t\t\t\t{t['app']} /* {t['name']}.app */,\n" for t in targets)
w(f"\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{apps}\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n")
for t in targets:
    deps = "".join(f"\t\t\t\t{ref} /* {p} */,\n" for p, ref, bf in t["deps"])
    w(f"""		{t['target']} /* {t['name']} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {t['cfglist']} /* Build configuration list for PBXNativeTarget "{t['name']}" */;
			buildPhases = (
				{t['sources']} /* Sources */,
				{t['frameworks']} /* Frameworks */,
				{t['resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{SYNC} /* HCGTerminal */,
			);
			name = {t['name']};
			packageProductDependencies = (
{deps}			);
			productName = {t['name']};
			productReference = {t['app']} /* {t['name']}.app */;
			productType = "com.apple.product-type.application";
		}};
""")
w("/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */\n")
attrs = "".join(f"\t\t\t\t\t{t['target']} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n\t\t\t\t\t}};\n" for t in targets)
tlist = "".join(f"\t\t\t\t{t['target']} /* {t['name']} */,\n" for t in targets)
w(f"""		{PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {{
{attrs}				}};
			}};
			buildConfigurationList = {PROJ_CFGLIST} /* Build configuration list for PBXProject "HCGTerminal" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {MAINGROUP};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{PKGREF} /* XCLocalSwiftPackageReference "HCGTerminalKit" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {PRODUCTS} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
{tlist}			);
		}};
""")
w("/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */\n")
for t in targets:
    w(f"\t\t{t['resources']} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n")
for t in targets:
    w(f"\t\t{t['sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXSourcesBuildPhase section */\n\n/* Begin XCBuildConfiguration section */\n")
w(proj_cfg(PROJ_DEBUG, "Debug")); w(proj_cfg(PROJ_RELEASE, "Release"))
for t in targets:
    w(target_cfg(t, t["debug"], "Debug")); w(target_cfg(t, t["release"], "Release"))
w("/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n")
def cfglist(id_, label, d, r):
    return f"\t\t{id_} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{d} /* Debug */,\n\t\t\t\t{r} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"
w(cfglist(PROJ_CFGLIST, 'PBXProject "HCGTerminal"', PROJ_DEBUG, PROJ_RELEASE))
for t in targets:
    w(cfglist(t["cfglist"], f'PBXNativeTarget "{t["name"]}"', t["debug"], t["release"]))
w("/* End XCConfigurationList section */\n\n/* Begin XCLocalSwiftPackageReference section */\n")
w(f"\t\t{PKGREF} /* XCLocalSwiftPackageReference \"HCGTerminalKit\" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = HCGTerminalKit;\n\t\t}};\n")
w("/* End XCLocalSwiftPackageReference section */\n\n/* Begin XCSwiftPackageProductDependency section */\n")
for t in targets:
    for p, ref, bf in t["deps"]:
        w(f"\t\t{ref} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {p};\n\t\t}};\n")
w("/* End XCSwiftPackageProductDependency section */\n\t};\n")
w(f"\trootObject = {PROJECT} /* Project object */;\n}}\n")

proj = os.path.join(root, "HCGTerminal.xcodeproj")
os.makedirs(os.path.join(proj, "project.xcworkspace"), exist_ok=True)
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write("".join(out))
open(os.path.join(proj, "project.xcworkspace", "contents.xcworkspacedata"), "w").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
for t in targets:
    ref = f"""<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{t['target']}"
               BuildableName = "{t['name']}.app"
               BlueprintName = "{t['name']}"
               ReferencedContainer = "container:HCGTerminal.xcodeproj">
            </BuildableReference>"""
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    open(os.path.join(proj, "xcshareddata", "xcschemes", f"{t['name']}.xcscheme"), "w").write(scheme)
print("ok")
