/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import <SystemConfiguration/SystemConfiguration.h>


#import "NSArray+Utils.h"
#import "NSString+Gecko.h"
#import "NSString+Utils.h"
#import "NSWorkspace+Utils.h"

#import "PreferenceManager.h"

// Must be after PreferenceManager.h to pick up Cocoa headers.
#import <Sparkle/Sparkle.h>

#import "AppDirServiceProvider.h"
#import "UserDefaults.h"
#import "CHBrowserService.h"
#import "CHISupportsOwner.h"
#import "CmXULAppInfo.h"

#include "nsString.h"
#include "nsCategoryManagerUtils.h"
#include "nsCRT.h"
#include "nsWeakReference.h"
#include "nsIServiceManager.h"
#include "nsIObserver.h"
#include "nsProfileDirServiceProvider.h"
#include "nsIPrefService.h"
#include "nsIPrefBranch2.h"
#include "nsIPluginHost.h"
#include "nsIPluginTag.h"
#include "nsEmbedAPI.h"
#include "nsAppDirectoryServiceDefs.h"
#include "nsIStyleSheetService.h"
#include "nsNetUtil.h"
#include "nsStaticComponents.h"
#include "nsILocalFileMac.h"
#include "nsDirectoryServiceDefs.h"
#include "nsINIParser.h"
#include "nsIFontEnumerator.h"

#define CUSTOM_PROFILE_DIR  "CAMINO_PROFILE_DIR"

NSString* const kPrefChangedNotification = @"PrefChangedNotification";
// userInfo entries:
NSString* const kPrefChangedPrefNameUserInfoKey = @"pref_name";

static NSString* const kAdBlockingCSSFile = @"ad_blocking_loader";
static NSString* const kAquaSelectCSSFile = @"aquaSelect";
static NSString* const kHTML5ElementsCSSFile = @"html5elements";

static NSString* const kAdBlockingChangedNotification = @"AdBlockingChanged";
static NSString* const kFlashblockChangedNotification = @"FlashblockChanged";

static NSString* const kJEPName = @"Java Embedding Plugin";
static NSString* const kAppleJavaName = @"Java Plug-In 2";
static NSString* const kAppleJavaNameLion = @"Java Applet Plug-in";

// This is an arbitrary version stamp that gets written to the prefs file.
// It can be used to detect when a new version of Camino is run that needs
// some prefs to be upgraded.
static const PRInt32 kCurrentPrefsVersion = 5;

// CheckCompatibility and WriteVersion are based on the versions in
// toolkit/xre/nsAppRunner.cpp.  This is done to provide forward
// compatibility in anticipation of Camino-on-XULRunner.

#define FILE_COMPATIBILITY_INFO NS_LITERAL_CSTRING("compatibility.ini")

static PRBool
CheckCompatibility(nsIFile* aProfileDir, const nsACString& aVersion,
                   const nsACString& aOSABI, nsIFile* aAppDir)
{
  nsCOMPtr<nsIFile> file;
  aProfileDir->Clone(getter_AddRefs(file));
  if (!file)
    return PR_FALSE;
  file->AppendNative(FILE_COMPATIBILITY_INFO);

  nsINIParser parser;
  nsCOMPtr<nsILocalFile> localFile(do_QueryInterface(file));
  nsresult rv = parser.Init(localFile);
  if (NS_FAILED(rv))
    return PR_FALSE;

  nsCAutoString buf;
  rv = parser.GetString("Compatibility", "LastVersion", buf);
  if (NS_FAILED(rv))
    return PR_FALSE;

  if (!aVersion.Equals(buf))
    return PR_FALSE;

  rv = parser.GetString("Compatibility", "LastOSABI", buf);
  if (NS_FAILED(rv))
    return PR_FALSE;

  if (!aOSABI.Equals(buf))
    return PR_FALSE;

  if (aAppDir) {
    rv = parser.GetString("Compatibility", "LastAppDir", buf);
    if (NS_FAILED(rv))
      return PR_FALSE;

    nsCOMPtr<nsILocalFile> lf;

    rv = NS_NewNativeLocalFile(buf, PR_FALSE,
                               getter_AddRefs(lf));
    if (NS_FAILED(rv))
      return PR_FALSE;

    PRBool eq;
    rv = lf->Equals(aAppDir, &eq);
    if (NS_FAILED(rv) || !eq)
      return PR_FALSE;
  }

  return PR_TRUE;
}

static void
WriteVersion(nsIFile* aProfileDir, const nsACString& aVersion,
             const nsACString& aOSABI, nsIFile* aAppDir)
{
  nsCOMPtr<nsIFile> file;
  aProfileDir->Clone(getter_AddRefs(file));
  if (!file)
    return;
  file->AppendNative(FILE_COMPATIBILITY_INFO);

  nsCOMPtr<nsILocalFile> lf = do_QueryInterface(file);

  nsCAutoString appDir;
  if (aAppDir)
    aAppDir->GetNativePath(appDir);

  PRFileDesc* fd = nsnull;
  lf->OpenNSPRFileDesc(PR_WRONLY | PR_CREATE_FILE | PR_TRUNCATE, 0600, &fd);
  if (!fd) {
    NS_ERROR("could not create output stream");
    return;
  }

  static const char kHeader[] = "[Compatibility]" NS_LINEBREAK
                                "LastVersion=";

  PR_Write(fd, kHeader, sizeof(kHeader) - 1);
  PR_Write(fd, PromiseFlatCString(aVersion).get(), aVersion.Length());

  static const char kOSABIHeader[] = NS_LINEBREAK "LastOSABI=";
  PR_Write(fd, kOSABIHeader, sizeof(kOSABIHeader) - 1);
  PR_Write(fd, PromiseFlatCString(aOSABI).get(), aOSABI.Length());

  static const char kAppDirHeader[] = NS_LINEBREAK "LastAppDir=";
  if (aAppDir) {
    PR_Write(fd, kAppDirHeader, sizeof(kAppDirHeader) - 1);
    PR_Write(fd, appDir.get(), appDir.Length());
  }

  static const char kNL[] = NS_LINEBREAK;
  PR_Write(fd, kNL, sizeof(kNL) - 1);

  PR_Close(fd);
}

@interface PreferenceManager(PreferenceManagerPrivate)

- (void)registerNotificationListener;
- (void)initUpdatePrefs;
- (void)ensureVisibleFilenameExtension;
- (void)cleanUpObsoletePrefs;
- (void)migrateOldDownloadPrefs;
- (void)migrateOldExternalLoadBehaviorPref;
// Returns the path of the download directory set in Internet Config.
- (NSString*)internetConfigDownloadDirectoryPref;

- (void)removeProfileURLClassifierDB;

- (void)termEmbedding:(NSNotification*)aNotification;
- (void)xpcomTerminate:(NSNotification*)aNotification;

- (void)showLaunchFailureAndQuitWithErrorTitle:(NSString*)inTitleFormat errorMessage:(NSString*)inMessageFormat;

- (void)setAcceptLanguagesPref;
- (void)setLocalePref;

- (void)configureProxies;
- (BOOL)updateOneProxy:(NSDictionary*)configDict
    protocol:(NSString*)protocol
    proxyEnableKey:(NSString*)enableKey
    proxyURLKey:(NSString*)urlKey
    proxyPortKey:(NSString*)portKey;

- (void)registerForProxyChanges;
- (void)readSystemProxySettings;

// Loads/unloads the Flashblock style sheet.
- (void)setFlashblockStyleSheetLoaded:(BOOL)inLoad;
// Loads/unloads the bundled CSS file with the given name (without extension).
- (void)setBundledStyleSheet:(NSString*)filename loaded:(BOOL)load;
// Loads/unloads the given style sheet, with type |type| (one of the values
// from nsIStyleSheetService).
- (void)setStyleSheet:(nsIURI *)cssFileURI
               loaded:(BOOL)load
             withType:(unsigned long)sheetType;
- (void)updatePluginEnableState;
- (BOOL)isPluginInstalledForType:(const char*)mimeType;
- (BOOL)isFlashblockAllowed;

- (NSString*)pathForSpecialDirectory:(const char*)specialDirectory;

// the path to the default system download folder
- (NSString*)geckoDefaultDownloadDirectory;
// the path to the users's desktop folder
- (NSString*)geckoDesktopDirectory;

@end

#pragma mark -

//
// PrefChangeObserver
//
// We create one of these each time someone adds a pref observer.
//
class PrefChangeObserver : public nsIObserver
{
public:
                        PrefChangeObserver(id inObject)  // inObject can be nil
                        : mObject(inObject)
                        {}

  virtual               ~PrefChangeObserver()
                        {}

  NS_DECL_ISUPPORTS
  NS_DECL_NSIOBSERVER

  id                    GetObject() const { return mObject; }
  nsresult              RegisterForPref(const char* inPrefName);
  nsresult              UnregisterForPref(const char* inPrefName);

protected:

  id                    mObject;    // not retained
};

NS_IMPL_ISUPPORTS1(PrefChangeObserver, nsIObserver);

nsresult
PrefChangeObserver::RegisterForPref(const char* inPrefName)
{
  nsresult rv;
  nsCOMPtr<nsIPrefBranch2> pbi = do_GetService(NS_PREFSERVICE_CONTRACTID, &rv);
  if (NS_FAILED(rv)) return rv;
  return pbi->AddObserver(inPrefName, this, PR_FALSE);
}

nsresult
PrefChangeObserver::UnregisterForPref(const char* inPrefName)
{
  nsresult rv;
  nsCOMPtr<nsIPrefBranch2> pbi = do_GetService(NS_PREFSERVICE_CONTRACTID, &rv);
  if (NS_FAILED(rv)) return rv;
  return pbi->RemoveObserver(inPrefName, this);
}

NS_IMETHODIMP
PrefChangeObserver::Observe(nsISupports* aSubject, const char* aTopic, const PRUnichar* aSomeData)
{
  if (nsCRT::strcmp(aTopic, "nsPref:changed") != 0)
    return NS_OK;   // not a pref changed notification

  NSDictionary* userInfoDict = [NSDictionary dictionaryWithObject:[NSString stringWithPRUnichars:aSomeData]
                                                           forKey:kPrefChangedPrefNameUserInfoKey];

  [[NSNotificationCenter defaultCenter] postNotificationName:kPrefChangedNotification
                                                      object:mObject
                                                    userInfo:userInfoDict];
  return NS_OK;
}

// This is a little wrapper for the C++ observer class,
// which takes care of registering and unregistering the observer.
@interface PrefChangeObserverOwner : CHISupportsOwner
{
@private
  NSString*           mPrefName;
}

- (id)initWithPrefName:(NSString*)inPrefName object:(id)inObject;
- (BOOL)hasObject:(id)inObject;

@end

@implementation PrefChangeObserverOwner

- (id)initWithPrefName:(NSString*)inPrefName object:(id)inObject
{
  PrefChangeObserver* changeObserver = new PrefChangeObserver(inObject);
  if ((self = [super initWithValue:(nsISupports*)changeObserver])) {   // retains it
    mPrefName = [inPrefName retain];
#if DEBUG
    NSLog(@"registering observer %@ on %@", self, mPrefName);
#endif
    changeObserver->RegisterForPref([mPrefName UTF8String]);
  }
  return self;
}

- (void)dealloc
{
#if DEBUG
  NSLog(@"unregistering observer %@ on %@", self, mPrefName);
#endif

  PrefChangeObserver* changeObserver = reinterpret_cast<PrefChangeObserver*>([super value]);
  if (changeObserver)
    changeObserver->UnregisterForPref([mPrefName UTF8String]);

  [mPrefName release];
  [super dealloc];
}

- (BOOL)hasObject:(id)inObject
{
  PrefChangeObserver* changeObserver = reinterpret_cast<PrefChangeObserver*>([super value]);
  return (changeObserver && (changeObserver->GetObject() == inObject));
}

@end

#pragma mark -

@implementation PreferenceManager

static PreferenceManager* gSharedInstance = nil;
#if DEBUG
static BOOL gMadePrefManager;
#endif

+ (PreferenceManager*)sharedInstance
{
  if (!gSharedInstance) {
#if DEBUG
    if (gMadePrefManager)
      NSLog(@"Recreating preferences manager on shutdown!");
    gMadePrefManager = YES;
#endif
    gSharedInstance = [[PreferenceManager alloc] init];
  }

  return gSharedInstance;
}

+ (PreferenceManager*)sharedInstanceDontCreate
{
  return gSharedInstance;
}

- (id)init
{
  if ((self = [super init])) {
    mRunLoopSource = NULL;

    [self registerNotificationListener];

    if ([self initMozillaPrefs] == NO) {
      // We should never get here!
      NSLog (@"Failed to initialize Mozilla prefs!");
    }

    [self initUpdatePrefs];
    [self ensureVisibleFilenameExtension];
    [self cleanUpObsoletePrefs];

    mDefaults = [NSUserDefaults standardUserDefaults];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (self == gSharedInstance)
    gSharedInstance = nil;

  [mProfilePath release];
  [super dealloc];
}

- (void)termEmbedding:(NSNotification*)aNotification
{
  NS_IF_RELEASE(mPrefs);
  // Remove our runloop observer.
  if (mRunLoopSource) {
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), mRunLoopSource, kCFRunLoopCommonModes);
    CFRelease(mRunLoopSource);
    mRunLoopSource = NULL;
  }
}

- (void)xpcomTerminate:(NSNotification*)aNotification
{
  [mPrefChangeObservers release];
  mPrefChangeObservers = nil;

  // This will notify observers that the profile is about to go away.
  if (mProfileProvider) {
      mProfileProvider->Shutdown();
      // Directory service holds a strong ref to this as well.
      NS_RELEASE(mProfileProvider);
  }

  // Save prefs now, in case any termination listeners set prefs.
  [self savePrefsFile];

  [gSharedInstance release];
}

- (void)registerNotificationListener
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(termEmbedding:)
                                               name:kTermEmbeddingNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(xpcomTerminate:)
                                               name:kXPCOMShutDownNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(adBlockingPrefChanged:)
                                               name:kAdBlockingChangedNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(flashblockPrefChanged:)
                                               name:kFlashblockChangedNotification
                                             object:nil];
}

- (void)savePrefsFile
{
  nsCOMPtr<nsIPrefService> prefsService = do_GetService(NS_PREFSERVICE_CONTRACTID);
  if (prefsService)
      prefsService->SavePrefFile(nsnull);
}

- (void)showLaunchFailureAndQuitWithErrorTitle:(NSString*)inTitleFormat errorMessage:(NSString*)inMessageFormat
{
  NSString* applicationName = NSLocalizedStringFromTable(@"CFBundleName", @"InfoPlist", nil);

  NSString* errorString   = [NSString stringWithFormat:inTitleFormat, applicationName];
  NSString* messageString = [NSString stringWithFormat:inMessageFormat, applicationName];

  NSRunAlertPanel(errorString, messageString, NSLocalizedString(@"QuitButtonText", @""), nil, nil);
  [NSApp terminate:self];
}

- (BOOL)initMozillaPrefs
{
    nsresult rv;

    NSString* path = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    const char* binDirPath = [[path stringByStandardizingPath] fileSystemRepresentation];
    nsCOMPtr<nsILocalFile> binDir;
    rv = NS_NewNativeLocalFile(nsDependentCString(binDirPath), PR_TRUE, getter_AddRefs(binDir));
    if (NS_FAILED(rv)) {
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureBinPathMsg", @"")];
      // not reached
      return NO;
    }

    // This shouldn't be needed since we are initing XPCOM with this
    // directory but causes a (harmless) warning if not defined.
    setenv("MOZILLA_FIVE_HOME", binDirPath, 1);

    // Check for a custom profile, first from -profile, then in the environment.
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    const char* customProfilePath = [[defaults stringForKey:USER_DEFAULTS_PROFILE_KEY] fileSystemRepresentation];
    if (!customProfilePath)
      customProfilePath = getenv(CUSTOM_PROFILE_DIR);

    // Based on whether a custom path is set, figure out what the
    // profile path should be.
    const char* profileDirectory;
    if (!customProfilePath) {
      // If it isn't, we then check the 'mozProfileDirName' key in our Info.plist file
      // and use the regular Application Support/<mozProfileDirName>, and Caches/<mozProfileDirName>
      // folders.
      NSString* dirString = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"mozProfileDirName"];
      if (dirString)
        profileDirectory = [dirString fileSystemRepresentation];
      else {
        NSLog(@"mozNewProfileDirName key missing from Info.plist file. Using default profile directory");
        profileDirectory = "Camino";
      }
    }
    else {
      // If we have a custom profile path, let's just use that.
      profileDirectory = customProfilePath;
      mIsCustomProfile = YES;
    }

    // Supply our own directory service provider, so we can control where
    // the registry and profiles are located.
    AppDirServiceProvider* provider = new AppDirServiceProvider(profileDirectory, mIsCustomProfile);

    if (!provider) {
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureMsg", @"")];
      // not reached
      return NO;
    }

    nsCOMPtr<nsIDirectoryServiceProvider> dirProvider = (nsIDirectoryServiceProvider*)provider;

    const char* executablePath = [[[NSBundle mainBundle] executablePath] fileSystemRepresentation];
    nsCOMPtr<nsILocalFile> executable;
    NS_NewNativeLocalFile(nsDependentCString(executablePath),
                          PR_TRUE, getter_AddRefs(executable));

    nsCOMPtr<nsIFile> profileDir;
    PRBool bogus = PR_FALSE;
    rv = dirProvider->GetFile(NS_APP_USER_PROFILES_ROOT_DIR, &bogus,
                              getter_AddRefs(profileDir));
    if (NS_FAILED(rv)) {
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureProfilePathMsg", @"")];
      // not reached
      return NO;
    }
    nsCOMPtr<nsIFile> cacheParentDir;
    rv = dirProvider->GetFile(NS_APP_USER_PROFILE_LOCAL_50_DIR, &bogus,
                              getter_AddRefs(cacheParentDir));
    if (NS_FAILED(rv)) {
      cacheParentDir = profileDir;
    }

    nsCAutoString version;
    version.Assign([[XULAppInfo version] UTF8String]);
    version.Append('_');
    version.Append([[XULAppInfo appBuildID] UTF8String]);
    version.Append('/');
    version.Append([[XULAppInfo platformVersion] UTF8String]);
    version.Append('_');
    version.Append([[XULAppInfo platformBuildID] UTF8String]);

#ifdef __ppc__
    NS_NAMED_LITERAL_CSTRING(osABI, "Darwin_ppc-gcc3");
#else
#ifdef __i386__
    NS_NAMED_LITERAL_CSTRING(osABI, "Darwin_x86-gcc3");
#else
    NS_NAMED_LITERAL_CSTRING(osABI, "Darwin_UNKNOWN");
#endif
#endif

    PRBool versionOK = CheckCompatibility(profileDir, version, osABI, executable);

    if (!versionOK) {
      // This isn't the same version that previously used the selected
      // profile. Remove some caches from the profile, allowing them to
      // be regenerated. NS_InitEmbedding will reregister components,
      // generating compreg.dat and xpti.dat. Note that this occurs prior
      // to any profile lock check, because it's inconvenient to move the
      // profile lock check up. However, doing things this way should be
      // harmless. Note that WriteVersion isn't called until after the
      // profile lock check.
      nsCOMPtr<nsIFile> file;
      profileDir->Clone(getter_AddRefs(file));
      if (file) {
        const char* kVolatileProfileFiles[] = {
          "compatibility.ini",
          "compreg.dat",
          "pluginreg.dat",
          "xpti.dat",
          "XUL.mfasl",
          nsnull
        };

        // dummy name, will be replaced with real filenames from the list above
        file->AppendNative(NS_LITERAL_CSTRING("M"));

        const char** filenames = kVolatileProfileFiles;
        const char* filename;
        while ((filename = *filenames)) {
          file->SetNativeLeafName(nsDependentCString(filename));
          file->Remove(PR_FALSE);
          filenames++;
        }
      }
    }

    rv = NS_InitEmbedding(binDir, dirProvider,
                          kPStaticModules, kStaticModuleCount);
    if (NS_FAILED(rv)) {
      NSLog(@"Embedding init failed!");
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureInitEmbeddingMsg", @"")];
      // not reached
      return NO;
    }

    NSString* profilePath = [self profilePath];
    if (!profilePath) {
      NSLog(@"Failed to determine profile path!");
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureProfilePathMsg", @"")];
      // not reached
      return NO;
    }

    rv = NS_NewProfileDirServiceProvider(PR_TRUE, &mProfileProvider);
    if (NS_FAILED(rv)) {
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureMsg", @"")];

      // not reached
      return NO;
    }
    mProfileProvider->Register();

    rv = mProfileProvider->SetProfileDir(profileDir, cacheParentDir);
    if (NS_FAILED(rv)) {
      if (rv == NS_ERROR_FILE_ACCESS_DENIED) {
        [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"AlreadyRunningAlert", @"")
                                        errorMessage:NSLocalizedString(@"AlreadyRunningMsg", @"")];
      }
      else {
        [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                        errorMessage:NSLocalizedString(@"StartupFailureProfileSetupMsg", @"")];
      }
      // not reached
      return NO;
    }
    // XRE has code to create components in the profile-after-change category
    // after sending the profile-after-change notification, but nothing else
    // does. We don't use XRE, but need the timer component that's registered
    // there, so create those components ourselves here (since SetProfileDir
    // is what sends the profile-after-change for us, so this is the closest
    // point).
    (void)NS_CreateServicesFromCategory("profile-after-change", nsnull,
                                        "profile-after-change");

    nsCOMPtr<nsIPrefBranch> prefs(do_GetService(NS_PREFSERVICE_CONTRACTID));
    if (!prefs) {
      [self showLaunchFailureAndQuitWithErrorTitle:NSLocalizedString(@"StartupFailureAlert", @"")
                                      errorMessage:NSLocalizedString(@"StartupFailureNoPrefsMsg", @"")];
      // not reached
      return NO;
    }

    mPrefs = prefs;
    NS_ADDREF(mPrefs);

    [self syncMozillaPrefs];

    if (!versionOK)
      WriteVersion(profileDir, version, osABI, executable);

    // Send out "embedding-initialized" notification.
    [[NSNotificationCenter defaultCenter] postNotificationName:kInitEmbeddingNotification object:nil];

    return YES;
}

- (void)initUpdatePrefs
{
  // If the Camino 1.6-style settings are in place, upgrade to the new method.
  // Sparkle has code to try to handle this, but it will change the update
  // interval to its own default in NSUserDefaults, stomping our value in the
  // Info.plist, so clean it up ourselves.
  // This block can be removed in some later release, after we can assume that
  // everyone has run something later than 1.6.x
  NSString* const kSparkleCheckIntervalKey = @"SUScheduledCheckInterval";
  NSString* const kSparkleUpdateChecksEnabled = @"SUEnableAutomaticChecks";
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kSparkleCheckIntervalKey]) {
    BOOL wasEnabled = [defaults integerForKey:kSparkleCheckIntervalKey] > 0;
    [defaults removeObjectForKey:kSparkleCheckIntervalKey];
    if (wasEnabled)
      [defaults removeObjectForKey:kSparkleUpdateChecksEnabled];
    else
      [[SUUpdater sharedUpdater] setAutomaticallyChecksForUpdates:NO];
  }

  NSBundle* mainBundle = [NSBundle mainBundle];
  if (![[mainBundle objectForInfoDictionaryKey:kSparkleUpdateChecksEnabled] boolValue]) {
    // If SUEnableAutomaticChecks is set to YES in the user's prefs, that will
    // override our plist setting, and Sparkle will check for updates anyway,
    // which shouldn't happen. In the 2.0+ setup, SUEnableAutomaticChecks should
    // never be set to YES at the defaults level (the options are NO at the
    // defaults level, or YES at the plist level and nothing at the user level),
    // so just unconditionally clear it if that somehow happens.
    if ([[defaults objectForKey:kSparkleUpdateChecksEnabled] boolValue])
      [defaults removeObjectForKey:kSparkleUpdateChecksEnabled];
    // If updates are disabled for this build, don't bother setting up the
    // manifest URL.
    return;
  }

  // Get the base auto-update manifest URL.
  NSString* baseURL = [self getStringPref:kGeckoPrefUpdateURLOverride
                              withSuccess:NULL];
  if (![baseURL length])
    baseURL = [self getStringPref:kGeckoPrefUpdateURL withSuccess:NULL];

  NSString* manifestURL = @"";
  if ([baseURL length]) {
    // Append the parameters we might be interested in.
    NSString* intlUAString = [self getStringPref:kGeckoPrefUserAgentMultiLangAddition
                                     withSuccess:NULL];
    NSArray* languages = [mainBundle localizations];
    NSString* currentLanguage = [[NSBundle preferredLocalizationsFromArray:languages] firstObject];
    if (currentLanguage)
      currentLanguage = [NSLocale canonicalLocaleIdentifierFromString:currentLanguage];
    else
      currentLanguage = @"en";
    manifestURL = [NSString stringWithFormat:@"%@?os=%@&arch=%@&version=%@&intl=%d&lang=%@",
                   baseURL,
                   [NSWorkspace osVersionString],
#if defined(__ppc__)
                   @"ppc",
#elif defined(__i386__)
                   @"x86",
#else
#error Unknown Architecture
#endif
                   [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                   ([intlUAString length] ? 1 : 0),
                   currentLanguage];
  }
  [[SUUpdater sharedUpdater] setFeedURL:[NSURL URLWithString:manifestURL]];
}

- (void)ensureVisibleFilenameExtension
{
  // Clean up after 2.1 development builds that allowed the user to kill the
  // extension by checking the hidden extension checkbox. A user may inherit
  // a default from the Finder and thus not have the key, so set the key 
  // unconditionally to prevent extension loss.
  // After no one is migrating from 2.0.x or a 2.1 development build, this can
  // be changed to only run once by checking for the key first.
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:NO forKey:@"NSNavLastUserSetHideExtensionButtonState"];
}

- (void)cleanUpObsoletePrefs
{
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

  // Remove old 0.8-era toolbar configuration prefs that are no longer functional.
  [defaults removeObjectForKey:@"NSToolbar Configuration preferences.toolbar"];

  // Avoid the General Prefs missing-icon problem for users who have migrated to 1.6+
  // from older versions who had changed the toolbar display prefs (with the now-removed widget).
  // When the widget was used to change the toolbar configuration, it saved the bundle IDs
  // of the pref panes. When an ID changed, the stale data in the plist caused missing icons.
  // Turns out we don't need the bundle IDs at all, so just delete them from the plist.
  NSMutableDictionary* prefsToolbarConfiguration = [[[defaults objectForKey:@"NSToolbar Configuration preferences.toolbar.1"] mutableCopy] autorelease];

  [prefsToolbarConfiguration removeObjectForKey:@"TB Item Identifiers"];
  [defaults setObject:prefsToolbarConfiguration forKey:@"NSToolbar Configuration preferences.toolbar.1"];

  // Clean up the 1.6.x + 10.6 + Java mess.
  const char* kSuppressionPref = "camino.java_suppressed";
  const char* kOldValuePref = "camino.java_enabled_pre_suppression";
  BOOL javaSuppressed = [self getBooleanPref:kSuppressionPref withSuccess:NULL];
  if (javaSuppressed) {
    BOOL prefExisted = NO;
    BOOL javaPreviouslyEnabled = [self getBooleanPref:kOldValuePref
                                          withSuccess:&prefExisted];
    [self clearPref:kSuppressionPref];
    [self clearPref:kOldValuePref];
    [self setPref:kGeckoPrefEnableJava toBoolean:(!prefExisted ||
                                                  javaPreviouslyEnabled)];
  }
}

// Convert an Apple locale (or language with the dialect specified) from the form "en_GB"
// to the "en-gb" form required for HTTP accept-language headers.
// If the locale isn't in the expected form we return nil. (Systems upgraded
// from 10.1 report human readable locales (e.g. "English")).
// Apple switched to the "en-GB" format in 10.4, so once support for PPC is
// dropped, the localeParts-handling section of this method can be removed.
+ (NSString*)convertLocaleToHTTPLanguage:(NSString*)inAppleLocale
{
    NSString* r = nil;
    if (inAppleLocale) {
      NSMutableString* language = [NSMutableString string];
      NSArray* localeParts = [inAppleLocale componentsSeparatedByString:@"_"];

      [language appendString:[localeParts objectAtIndex:0]];
      if ([localeParts count] > 1) {
        [language appendString:@"-"];
        [language appendString:[[localeParts objectAtIndex:1] lowercaseString]];
      }

      // We accept standalone primary subtags (e.g. "en") and also a primary
      // subtag with additional subtags of between two and eight characters
      // long. We ignore i- and x- primary subtags. By convention the 
      // accept-language subtags are lowercase (and some servers require this).
      if ([language length] == 2 ||
          ([language length] >= 5 && [language length] <= 13 && [language characterAtIndex:2] == '-'))
        r = [[NSString stringWithString:language] lowercaseString];
    }
    return r;
}

- (void)syncMozillaPrefs
{
  // Avoid calling anything in this method that will cause plug-in enumeration
  // (see bug 667441).
  if (!mPrefs) {
    NSLog(@"Mozilla prefs not set up successfully");
    return;
  }

  PRInt32 lastRunPrefsVersion = 0;
  mPrefs->GetIntPref("camino.prefs_version", &lastRunPrefsVersion);
  mLastRunPrefsVersion = lastRunPrefsVersion;

  // Starting with pref version 2, we migrated to the toolkit versions of
  // all our download manager preferences.
  if (mLastRunPrefsVersion < 2)
    [self migrateOldDownloadPrefs];

  // Starting with Gecko 1.9.1, the download directory is set in Gecko prefs,
  // rather than Internet Config. We need to move the setting over for users
  // when they upgrade.
  if (mLastRunPrefsVersion && mLastRunPrefsVersion < 3)
    [self setDownloadDirectoryPath:[self internetConfigDownloadDirectoryPref]];

  if (mLastRunPrefsVersion && mLastRunPrefsVersion < 4) {
    // The Java pref flipped in Camino 2.1; ensure that Gecko has the correct
    // state.
    [self updatePluginEnableState];

    // browser.reuse_window pref migrated to browser.link.open_external (and
    // the default behavior changed).
    [self migrateOldExternalLoadBehaviorPref];

    // The url-classifier database moved to the Caches folder. Delete the
    // existing database unless Camino is running with a custom profile, in
    // which case the caches all live in the profile.
    if (!mIsCustomProfile)
      [self removeProfileURLClassifierDB];
  }

#if defined(__ppc__)
  if (mLastRunPrefsVersion < 5) {
    // PPC users don't have access to a version of Flash without serious known
    // vulnerabilities, so enable Flash blocking to help increase security.
    [self setPref:kGeckoPrefBlockFlash toBoolean:YES];
  }
#endif

  mPrefs->SetIntPref("camino.prefs_version", kCurrentPrefsVersion);

  // Fix up the cookie prefs. If 'p3p' or 'accept foreign cookies' are on,
  // remap them to something that Camino can deal with.
  PRInt32 acceptCookies = 0;
  static const char* kCookieBehaviorPref = kGeckoPrefCookieDefaultAcceptPolicy;
  mPrefs->GetIntPref(kCookieBehaviorPref, &acceptCookies);
  if (acceptCookies == 3) {     // p3p, assume all cookies on
    acceptCookies = kCookieAcceptAll;
    mPrefs->SetIntPref(kCookieBehaviorPref, acceptCookies);
  }

  [self configureProxies];

  [self setAcceptLanguagesPref];
  [self setLocalePref];

  // Register a Gecko pref observer to watch for changes via about:config.
  // We do this here rather than in |-registerNotificationListener:| because
  // the Gecko pref observer component isn't set up then.  |-xpcomTerminate:|
  // automatically cleans up the Gecko pref observer, and |-dealloc:| 
  // automatically cleans up the NSNotificationCenter observer.
  [self addObserver:self forPref:kGeckoPrefForceAquaSelects];
  [self addObserver:self forPref:kGeckoPrefEnableJava];
  [self addObserver:self forPref:kGeckoPrefDisabledPluginPrefixes];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(internallyObservedPrefChanged:)
                                               name:kPrefChangedNotification
                                             object:self];

  // Make sure the homepage has been set up.
  PRInt32 homepagePrefExists;
  if (NS_FAILED(mPrefs->PrefHasUserValue(kGeckoPrefHomepageURL, &homepagePrefExists)) ||
      !homepagePrefExists)
  {
    NSString* defaultHomepage = NSLocalizedStringFromTable(@"HomePageDefault", @"WebsiteDefaults", nil);
    // Check that we actually got a sane value back before storing it.
    if (![defaultHomepage isEqualToString:@"HomePageDefault"])
      [self setPref:kGeckoPrefHomepageURL toString:defaultHomepage];
  }
}

- (void)setAcceptLanguagesPref
{
  // Determine if the user specified a language override. If so, use it;
  // otherwise, work out the languages from the system preferences.
  BOOL userProvidedLangOverride = NO;
  NSString* userLanguageOverride = [self getStringPref:kGeckoPrefAcceptLanguagesOverride
                                           withSuccess:&userProvidedLangOverride];

  if (userProvidedLangOverride && [userLanguageOverride length] > 0) {
    [self setPref:kGeckoPrefAcceptLanguages toString:userLanguageOverride];
  }
  else {
    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    NSArray* languages = [defs objectForKey:@"AppleLanguages"];
    NSMutableArray* acceptableLanguages = [NSMutableArray array];

    // Build the list of languages the user understands (from System Preferences | International).
    BOOL languagesOkaySoFar = YES;
    int indexOfGenericEnglish = -1;
    BOOL englishDialectExists = NO;
    for (unsigned int i = 0; languagesOkaySoFar && i < [languages count]; ++i) {
      NSString* language = [PreferenceManager convertLocaleToHTTPLanguage:[languages objectAtIndex:i]];
      if (language) {
        [acceptableLanguages addObject:language];
        if ((indexOfGenericEnglish == -1) && !englishDialectExists &&
            [language isEqualToString:@"en"])
        {
          indexOfGenericEnglish = i;
        }
        else if (!englishDialectExists && [language hasPrefix:@"en-"]) {
          englishDialectExists = YES;
        }
      }
      else {
        // If we don't understand a language, don't set any, rather than risk
        // leaving the user with their Nth choice (which may be one Apple made
        // and they don't actually read). This mainly occurs on systems upgraded
        // from 10.1; see convertLocaleToHTTPLanguage().
        NSLog(@"Unable to set languages - language '%@' not a valid ISO language identifier",
              [languages objectAtIndex:i]);
        languagesOkaySoFar = NO;
      }
    }

    // Some servers will disregard a generic 'en', causing a fallback to a
    // subsequent language (see bug 300905). So if the user has only a generic
    // 'en', insert 'en-us' before 'en'.
    if ((indexOfGenericEnglish != -1) && !englishDialectExists)
      [acceptableLanguages insertObject:@"en-us" atIndex:indexOfGenericEnglish];

    // If we understood all the languages in the list, set the accept-language
    // header. Note that Necko will determine quality factors itself.
    if (languagesOkaySoFar && [acceptableLanguages count] > 0) {
      // Gecko will only assign 10 unique qualilty factors, and duplicate
      // quality factors breaks the user's ordering (which, combined with the
      // 'en' issue above and the fact that Apple's default list has well over
      // 10 languages, means the wrong thing can happen with a default list).
      if ([acceptableLanguages count] > 10) {
        NSRange dropRange = NSMakeRange(10, [acceptableLanguages count] - 10);
        [acceptableLanguages removeObjectsInRange:dropRange];
      }
      NSString* acceptLangHeader = [acceptableLanguages componentsJoinedByString:@","];
      [self setPref:kGeckoPrefAcceptLanguages toString:acceptLangHeader];
    }
    else {
      // Fall back to the "en-us, en" default from all-camino.js and clear
      // any existing user pref.
      [self clearPref:kGeckoPrefAcceptLanguages];
    }
  }
}

- (void)setLocalePref
{
  // Use the user-selected pref for the user agent locale if it exists.
  NSString* uaLocale = [self getStringPref:kGeckoPrefUserAgentLocaleOverride
                               withSuccess:NULL];

  if (![uaLocale length]) {
    // Find the active localization nib's name and make sure it's in
    // "ab" or "ab-CD" form.
    NSArray* localizations = [[NSBundle mainBundle] preferredLocalizations];
    if ([localizations count]) {
      CFStringRef activeLocalization =
        ::CFLocaleCreateCanonicalLocaleIdentifierFromString(
            NULL, (CFStringRef)[localizations objectAtIndex:0]);
      if (activeLocalization) {
        uaLocale = [PreferenceManager
                     convertLocaleToHTTPLanguage:(NSString*)activeLocalization];
        ::CFRelease(activeLocalization);
      }
    }
  }

  if (uaLocale && [uaLocale length]) {
    [self setPref:kGeckoPrefUserAgentLocale toString:uaLocale];
  }
  else {
    NSLog(@"Unable to determine user interface locale\n");
    // Fall back to the "en-US" default from all.js.  Clear any existing
    // user pref.
    [self clearPref:kGeckoPrefUserAgentLocale];
  }
}

- (void)setDownloadDirectoryPath:(NSString*)aPath
{
  int folderType = kDownloadsFolderDownloads;
  if ([aPath isEqualToString:[self geckoDesktopDirectory]]) {
    folderType = kDownloadsFolderDesktop;
  }
  else if (aPath && ![aPath isEqualToString:[self geckoDefaultDownloadDirectory]]) {
    folderType = kDownloadsFolderCustom;
    [self setPref:kGeckoPrefDownloadsDir toFile:[NSURL fileURLWithPath:aPath]];
  }
  [self setPref:kGeckoPrefDownloadsFolderList toInt:folderType];
}

- (void)loadUserStylesheets
{
  [self setBundledStyleSheet:kHTML5ElementsCSSFile loaded:YES];
  if ([self getBooleanPref:kGeckoPrefBlockAds withSuccess:NULL])
    [self setBundledStyleSheet:kAdBlockingCSSFile loaded:YES];
  BOOL flashblockAllowed = [self isFlashblockAllowed];
  if (flashblockAllowed && [self getBooleanPref:kGeckoPrefBlockFlash withSuccess:NULL])
    [self setFlashblockStyleSheetLoaded:YES];
  if ([self getBooleanPref:kGeckoPrefForceAquaSelects withSuccess:NULL])
    [self setBundledStyleSheet:kAquaSelectCSSFile loaded:YES];
}

#pragma mark -

- (void)configureProxies
{
  [self readSystemProxySettings];
  [self registerForProxyChanges];
}

static void SCProxiesChangedCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void* /* info */)
{
  PreferenceManager* prefsManager = [PreferenceManager sharedInstanceDontCreate];
  [prefsManager readSystemProxySettings];
#if DEBUG
  NSLog(@"Updating proxies");
#endif
}

- (void)registerForProxyChanges
{
  if (mRunLoopSource)   // don't register twice
    return;

  SCDynamicStoreContext context = {0, NULL, NULL, NULL, NULL};

  SCDynamicStoreRef dynamicStoreRef = SCDynamicStoreCreate(NULL, CFSTR("ChimeraProxiesNotification"), SCProxiesChangedCallback, &context);
  if (dynamicStoreRef) {
    CFStringRef proxyIdentifier = SCDynamicStoreKeyCreateProxies(NULL);
    CFArrayRef  keyList = CFArrayCreate(NULL, (const void**)&proxyIdentifier, 1, &kCFTypeArrayCallBacks);

    Boolean set = SCDynamicStoreSetNotificationKeys(dynamicStoreRef, keyList, NULL);
    if (set) {
      mRunLoopSource = SCDynamicStoreCreateRunLoopSource(NULL, dynamicStoreRef, 0);
      if (mRunLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), mRunLoopSource, kCFRunLoopCommonModes);
        // We keep the ref to the source, so that we can remove it when the prefs manager is cleaned up.
      }
    }

    CFRelease(proxyIdentifier);
    CFRelease(keyList);
    CFRelease(dynamicStoreRef);
  }
}

- (BOOL)updateOneProxy:(NSDictionary*)configDict
  protocol:(NSString*)protocol
  proxyEnableKey:(NSString*)enableKey
  proxyURLKey:(NSString*)urlKey
  proxyPortKey:(NSString*)portKey
{
  BOOL gotProxy = NO;

  BOOL enabled = (BOOL)[[configDict objectForKey:enableKey] intValue];
  if (enabled) {
    NSString* protocolProxy = [configDict objectForKey:urlKey];
    int proxyPort = [[configDict objectForKey:portKey] intValue];
    if ([protocolProxy length] > 0 && proxyPort != 0) {
      [self setPref:[[NSString stringWithFormat:@"network.proxy.%@", protocol] UTF8String] toString:protocolProxy];
      [self setPref:[[NSString stringWithFormat:@"network.proxy.%@_port", protocol] UTF8String] toInt:proxyPort];
      gotProxy = YES;
    }
  }

  return gotProxy;
}

typedef enum EProxyConfig {
  eProxyConfig_Direct = 0,
  eProxyConfig_Manual,
  eProxyConfig_PAC,
  eProxyConfig_Direct4x,
  eProxyConfig_WPAD,
  eProxyConfig_Last
} EProxyConfig;

- (void)readSystemProxySettings
{
  // If the user has set kGeckoPrefProxyUsesSystemSettings to false, they want
  // to specify their own proxies (or a PAC), so don't read the OS proxy settings.
  if (![self getBooleanPref:kGeckoPrefProxyUsesSystemSettings withSuccess:NULL])
    return;

  PRInt32 curProxyType, newProxyType;
  mPrefs->GetIntPref("network.proxy.type", &curProxyType);
  newProxyType = curProxyType;

  mPrefs->ClearUserPref("network.proxy.http");
  mPrefs->ClearUserPref("network.proxy.http_port");
  mPrefs->ClearUserPref("network.proxy.ssl");
  mPrefs->ClearUserPref("network.proxy.ssl_port");
  mPrefs->ClearUserPref("network.proxy.ftp");
  mPrefs->ClearUserPref("network.proxy.ftp_port");
  mPrefs->ClearUserPref("network.proxy.gopher");
  mPrefs->ClearUserPref("network.proxy.gopher_port");
  mPrefs->ClearUserPref("network.proxy.socks");
  mPrefs->ClearUserPref("network.proxy.socks_port");
  mPrefs->ClearUserPref(kGeckoPrefProxyBypassList);

  // Get proxies from SystemConfiguration.
  NSDictionary* proxyConfigDict = (NSDictionary*)SCDynamicStoreCopyProxies(NULL);
  if (proxyConfigDict) {
    // look for PAC
    NSNumber* proxyAutoConfig = (NSNumber*)[proxyConfigDict objectForKey:(NSString*)kSCPropNetProxiesProxyAutoConfigEnable];
    NSString* proxyURLString  = (NSString*)[proxyConfigDict objectForKey:(NSString*)kSCPropNetProxiesProxyAutoConfigURLString];
    if ([proxyAutoConfig intValue] != 0 && [proxyURLString length] > 0) {
      NSLog(@"Using Proxy Auto-Config (PAC) file %@", proxyURLString);
      [self setPref:kGeckoPrefProxyAutoconfigURL toString:proxyURLString];
      newProxyType = eProxyConfig_PAC;
    }
    else {
      BOOL gotAProxy = NO;

      gotAProxy |= [self updateOneProxy:proxyConfigDict protocol:@"http"
                              proxyEnableKey:(NSString*)kSCPropNetProxiesHTTPEnable
                                 proxyURLKey:(NSString*)kSCPropNetProxiesHTTPProxy
                                proxyPortKey:(NSString*)kSCPropNetProxiesHTTPPort];

      gotAProxy |= [self updateOneProxy:proxyConfigDict protocol:@"ssl"
                              proxyEnableKey:(NSString*)kSCPropNetProxiesHTTPSEnable
                                 proxyURLKey:(NSString*)kSCPropNetProxiesHTTPSProxy
                                proxyPortKey:(NSString*)kSCPropNetProxiesHTTPSPort];

      gotAProxy |= [self updateOneProxy:proxyConfigDict protocol:@"ftp"
                              proxyEnableKey:(NSString*)kSCPropNetProxiesFTPEnable
                                 proxyURLKey:(NSString*)kSCPropNetProxiesFTPProxy
                                proxyPortKey:(NSString*)kSCPropNetProxiesFTPPort];

      gotAProxy |= [self updateOneProxy:proxyConfigDict protocol:@"gopher"
                              proxyEnableKey:(NSString*)kSCPropNetProxiesGopherEnable
                                 proxyURLKey:(NSString*)kSCPropNetProxiesGopherProxy
                                proxyPortKey:(NSString*)kSCPropNetProxiesGopherPort];

      gotAProxy |= [self updateOneProxy:proxyConfigDict protocol:@"socks"
                              proxyEnableKey:(NSString*)kSCPropNetProxiesSOCKSEnable
                                 proxyURLKey:(NSString*)kSCPropNetProxiesSOCKSProxy
                                proxyPortKey:(NSString*)kSCPropNetProxiesSOCKSPort];

      if (gotAProxy) {
        newProxyType = eProxyConfig_Manual;

        NSArray* exceptions = [proxyConfigDict objectForKey:(NSString*)kSCPropNetProxiesExceptionsList];
        if (exceptions) {
          NSString* sitesList = [exceptions componentsJoinedByString:@", "];
          if ([sitesList length] > 0)
            [self setPref:kGeckoPrefProxyBypassList toString:sitesList];
        }
      }
      else {
        // No proxy hosts found, so turn them off.
        newProxyType = eProxyConfig_Direct;
      }
    }

    [proxyConfigDict release];
  }

  if (newProxyType != curProxyType)
    mPrefs->SetIntPref("network.proxy.type", newProxyType);
}

#pragma mark -

- (void)adBlockingPrefChanged:(NSNotification*)inNotification
{
  BOOL adBlockingEnabled = [self getBooleanPref:kGeckoPrefBlockAds withSuccess:NULL];
  [self setBundledStyleSheet:kAdBlockingCSSFile loaded:adBlockingEnabled];
}

- (void)flashblockPrefChanged:(NSNotification*)inNotification
{
  BOOL allowed = [self isFlashblockAllowed];

  BOOL flashblockEnabled = allowed && [self getBooleanPref:kGeckoPrefBlockFlash withSuccess:NULL];
  [self setFlashblockStyleSheetLoaded:flashblockEnabled];
}

- (void)internallyObservedPrefChanged:(NSNotification*)inNotification
{
  const char *changedPref = [[[inNotification userInfo]
      objectForKey:kPrefChangedPrefNameUserInfoKey] UTF8String];

  if (strcmp(changedPref, kGeckoPrefForceAquaSelects) == 0) {
    BOOL aquaSelectEnabled = [self getBooleanPref:kGeckoPrefForceAquaSelects
                                      withSuccess:NULL];
    [self setBundledStyleSheet:kAquaSelectCSSFile loaded:aquaSelectEnabled];
  }
  else if ((strcmp(changedPref, kGeckoPrefEnableJava) == 0) ||
           (strcmp(changedPref, kGeckoPrefDisabledPluginPrefixes) == 0))
  {
    [self updatePluginEnableState];
  }
}

- (void)setFlashblockStyleSheetLoaded:(BOOL)inLoad
{
  // the URI of the Flashblock sheet in the chrome path
  nsCOMPtr<nsIURI> cssFileURI;
  nsresult rv = NS_NewURI(getter_AddRefs(cssFileURI), "chrome://flashblock/content/flashblock.css");
  if (NS_FAILED(rv))
    return;

  [self setStyleSheet:cssFileURI
               loaded:inLoad
             withType:nsIStyleSheetService::USER_SHEET];
}

- (void)setBundledStyleSheet:(NSString*)filename loaded:(BOOL)load
{
  NSString* cssFilePath = [[NSBundle mainBundle] pathForResource:filename
                                                          ofType:@"css"];
  if (![[NSFileManager defaultManager] isReadableFileAtPath:cssFilePath]) {
    NSLog(@"%@.css file not found in bundle", filename);
    return;
  }

  nsresult rv;
  nsCOMPtr<nsILocalFile> cssFile;
  rv = NS_NewNativeLocalFile(nsDependentCString(
      [cssFilePath fileSystemRepresentation]), PR_TRUE, getter_AddRefs(cssFile));
  if (NS_FAILED(rv))
    return;

  nsCOMPtr<nsIURI> cssFileURI;
  rv = NS_NewFileURI(getter_AddRefs(cssFileURI), cssFile);
  if (NS_FAILED(rv))
    return;

  unsigned long styleSheetType = nsIStyleSheetService::USER_SHEET;
  if ([filename isEqualToString:kHTML5ElementsCSSFile])
      styleSheetType = nsIStyleSheetService::AGENT_SHEET;

  [self setStyleSheet:cssFileURI
               loaded:load
             withType:styleSheetType];
}

- (void)setStyleSheet:(nsIURI *)cssFileURI
               loaded:(BOOL)load
             withType:(unsigned long)sheetType
{
  nsCOMPtr<nsIStyleSheetService> ssService =
      do_GetService("@mozilla.org/content/style-sheet-service;1");
  if (!ssService)
    return;

  PRBool alreadyRegistered = PR_FALSE;
  ssService->SheetRegistered(cssFileURI, sheetType, &alreadyRegistered);
  if (!load && alreadyRegistered)
    ssService->UnregisterSheet(cssFileURI, sheetType);
  else if (load && !alreadyRegistered)
    ssService->LoadAndRegisterSheet(cssFileURI, sheetType);
}

- (void)updatePluginEnableState
{
  nsCOMPtr<nsIPluginHost> pluginHost = do_GetService(MOZ_PLUGIN_HOST_CONTRACTID);
  if (!pluginHost)
    return;
  nsIPluginTag** plugins = NULL;
  PRUint32 pluginCount = 0;
  pluginHost->GetPluginTags(&pluginCount, &plugins);
  for (unsigned i = 0; i < pluginCount; i++) {
    nsCAutoString name;
    plugins[i]->GetName(name);
    plugins[i]->SetDisabled([self pluginShouldBeDisabled:name.get()] ?
        PR_TRUE : PR_FALSE);
    NS_RELEASE(plugins[i]);
  }
  nsMemory::Free(plugins);
}

- (BOOL)pluginShouldBeDisabled:(const char*)pluginName
{
  NSString* name = [NSString stringWithUTF8String:pluginName];
  if ([name hasPrefix:kJEPName] || [name hasPrefix:kAppleJavaName] ||
      [name hasPrefix:kAppleJavaNameLion])
  {
    // Java has a UI pref, so handle it specially.
    // Ideally Java would be detected by MIME type, but nsIPluginTag doesn't
    // expose MIME types, making it more trouble than it's worth.
    return ![self getBooleanPref:kGeckoPrefEnableJava withSuccess:NULL];
  }
  // The hidden disable pref is interpreted as a ;-separated set of name
  // prefixes of plugins to disable. Prefixes are used because some plugins
  // append version info to their name.
  NSString* prefixList = [self getStringPref:kGeckoPrefDisabledPluginPrefixes
                                 withSuccess:NULL];
  NSEnumerator* prefixEnumerator =
      [[prefixList componentsSeparatedByString:@";"] objectEnumerator];
  NSString* prefix;
  while ((prefix = [prefixEnumerator nextObject])) {
    NSString* trimmedPrefix = [prefix stringByTrimmingWhitespace];
    if ([prefix length] && [name hasPrefix:trimmedPrefix]) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)isPluginInstalledForType:(const char*)mimeType
{
  nsCOMPtr<nsIPluginHost> pluginHost = do_GetService(MOZ_PLUGIN_HOST_CONTRACTID);
  if (!pluginHost)
    return NO;
  nsresult rv = pluginHost->IsPluginEnabledForType(mimeType);
  // NS_ERROR_FAILURE indicates no plugin exists for the type.
  return rv != NS_ERROR_FAILURE;
}

- (BOOL)javaPluginCanBeEnabled
{
  return [self isPluginInstalledForType:"application/x-java-vm"];
}

- (BOOL)isFlashInstalled
{
  return [self isPluginInstalledForType:"application/x-shockwave-flash"];
}

#pragma mark -

- (NSURL*)getFilePref:(const char*)prefName withSuccess:(BOOL*)outSuccess
{
  NSURL* prefValue = nil;
  if (mPrefs) {
    nsCOMPtr<nsILocalFile> filePref;
    mPrefs->GetComplexValue(prefName, NS_GET_IID(nsILocalFile), getter_AddRefs(filePref));
    if (filePref) {
      nsAutoString path;
      filePref->GetPath(path);
      prefValue = [NSURL fileURLWithPath:[NSString stringWith_nsAString:path]];
    }
  }
  return prefValue;
}

- (NSString*)getStringPref:(const char*)prefName withSuccess:(BOOL*)outSuccess
{
  NSString* prefValue = @"";

  char* buf = nsnull;
  nsresult rv = NS_ERROR_FAILURE;
  if (mPrefs)
    rv = mPrefs->GetCharPref(prefName, &buf);

  if (NS_SUCCEEDED(rv) && buf) {
    // prefs are UTF-8
    prefValue = [NSString stringWithUTF8String:buf];
    free(buf);
    if (outSuccess) *outSuccess = YES;
  } else {
    if (outSuccess) *outSuccess = NO;
  }

  return prefValue;
}

- (NSColor*)getColorPref:(const char*)prefName withSuccess:(BOOL*)outSuccess
{
  // Colors are stored in hex (e.g. #FFFFFF) strings
  NSString* colorString = [self getStringPref:prefName withSuccess:outSuccess];
  NSColor*  returnColor = [NSColor blackColor];

  if ([colorString hasPrefix:@"#"] && [colorString length] == 7) {
    unsigned int redInt, greenInt, blueInt;
    sscanf([colorString UTF8String], "#%02x%02x%02x", &redInt, &greenInt, &blueInt);

    float redFloat    = ((float)redInt / 255.0);
    float greenFloat  = ((float)greenInt / 255.0);
    float blueFloat   = ((float)blueInt / 255.0);

    returnColor = [NSColor colorWithCalibratedRed:redFloat green:greenFloat blue:blueFloat alpha:1.0f];
    if (outSuccess) *outSuccess = YES;
  }
  else {
    if (outSuccess) *outSuccess = NO;
  }

  return returnColor;
}

- (BOOL)getBooleanPref:(const char*)prefName withSuccess:(BOOL*)outSuccess
{
  PRBool boolPref = PR_FALSE;
  nsresult rv = NS_ERROR_FAILURE;
  if (mPrefs)
    rv = mPrefs->GetBoolPref(prefName, &boolPref);

  if (outSuccess)
    *outSuccess = NS_SUCCEEDED(rv);

  return boolPref ? YES : NO;
}

- (int)getIntPref:(const char*)prefName withSuccess:(BOOL*)outSuccess
{
  PRInt32 intPref = 0;
  nsresult rv = NS_ERROR_FAILURE;
  if (mPrefs)
    rv = mPrefs->GetIntPref(prefName, &intPref);

  if (outSuccess)
    *outSuccess = NS_SUCCEEDED(rv);

  return intPref;
}

- (void)setPref:(const char*)prefName toFile:(NSURL*)value
{
  nsCOMPtr<nsILocalFile> filePref(do_CreateInstance("@mozilla.org/file/local;1"));
  if (mPrefs && filePref) {
    filePref->InitWithPath(NS_ConvertUTF8toUTF16([[value path] UTF8String]));
    mPrefs->SetComplexValue(prefName, NS_GET_IID(nsILocalFile), filePref);
  }
}

- (void)setPref:(const char*)prefName toString:(NSString*)value
{
  if (mPrefs)
    (void)mPrefs->SetCharPref(prefName, [value UTF8String]);
}

- (void)setPref:(const char*)prefName toInt:(int)value
{
  if (mPrefs)
    (void)mPrefs->SetIntPref(prefName, (PRInt32)value);
}

- (void)setPref:(const char*)prefName toBoolean:(BOOL)value
{
  if (mPrefs)
    (void)mPrefs->SetBoolPref(prefName, value ? PR_TRUE : PR_FALSE);
}

- (void)clearPref:(const char*)prefName
{
  if (mPrefs)
    (void)mPrefs->ClearUserPref(prefName);
}

- (NSString*)homePageUsingStartPage:(BOOL)checkStartupPagePref
{
  if (!mPrefs)
    return @"about:blank";

  // If |checkStartupPagePref|, always return the homepage, otherwise check the
  // user's pref for new windows.
  BOOL success = NO;
  int mode = kStartPageHome;
  if (checkStartupPagePref)
    mode = [self getIntPref:kGeckoPrefNewWindowStartPage withSuccess:&success];

  if (!success || mode == kStartPageHome) {
    NSString* homepagePref = [self getStringPref:kGeckoPrefHomepageURL withSuccess:NULL];
    if (!homepagePref)
      homepagePref = NSLocalizedStringFromTable(@"HomePageDefault", @"WebsiteDefaults", nil);

    if (homepagePref && [homepagePref length] > 0 && ![homepagePref isEqualToString:@"HomePageDefault"])
      return homepagePref;
  }

  return @"about:blank";
}

//
// -profilePath
//
// Returns the path for our post-0.8 profiles.
// We no longer have distinct profiles. The profile dir is the same as
// NS_APP_USER_PROFILES_ROOT_DIR - imposed by our own AppDirServiceProvider. Will
// return |nil| if there is a problem.
//
- (NSString*)profilePath
{
  if (!mProfilePath)
    mProfilePath = [[self pathForSpecialDirectory:NS_APP_USER_PROFILES_ROOT_DIR] retain];

  return mProfilePath;
}

- (NSString*)cacheParentDirPath
{
  return [self pathForSpecialDirectory:NS_APP_CACHE_PARENT_DIR];
}

- (NSString*)downloadDirectoryPath
{
  NSString* prefValue = nil;
  BOOL gotPref;
  int downloadFolder = [self getIntPref:kGeckoPrefDownloadsFolderList withSuccess:&gotPref];

  if (gotPref && (downloadFolder == kDownloadsFolderDesktop))
    prefValue = [[PreferenceManager sharedInstance] geckoDesktopDirectory];
  else if (gotPref && downloadFolder == kDownloadsFolderCustom)
    prefValue = [[self getFilePref:kGeckoPrefDownloadsDir withSuccess:NULL] path];
  else
    prefValue = [[PreferenceManager sharedInstance] geckoDefaultDownloadDirectory];

  return prefValue;
}

- (NSString*)geckoDefaultDownloadDirectory
{
  return [self pathForSpecialDirectory:NS_MAC_DEFAULT_DOWNLOAD_DIR];
}

- (NSString*)geckoDesktopDirectory
{
  return [self pathForSpecialDirectory:NS_MAC_DESKTOP_DIR];
}

- (NSString*)pathForSpecialDirectory:(const char*)specialDirectory
{
  nsCOMPtr<nsIFile> directoryFile;
  nsresult rv = NS_GetSpecialDirectory(specialDirectory,
                                       getter_AddRefs(directoryFile));
  if (NS_FAILED(rv))
    return nil;
  nsCAutoString nativePath;
  rv = directoryFile->GetNativePath(nativePath);
  if (NS_FAILED(rv))
    return nil;
  return [NSString stringWithUTF8String:nativePath.get()];
}

- (void)addObserver:(id)inObject forPref:(const char*)inPrefName
{
  if (!mPrefChangeObservers)
    mPrefChangeObservers = [[NSMutableDictionary alloc] initWithCapacity:4];

  NSString* prefName = [NSString stringWithUTF8String:inPrefName];

  // Get the array of pref observers for this pref.
  NSMutableArray* existingObservers = [mPrefChangeObservers objectForKey:prefName];
  if (!existingObservers) {
    existingObservers = [NSMutableArray arrayWithCapacity:1];
    [mPrefChangeObservers setObject:existingObservers forKey:prefName];
  }

  // Look for an existing observer with this target object.
  NSEnumerator* observersEnum = [existingObservers objectEnumerator];
  PrefChangeObserverOwner* curValue;
  while ((curValue = [observersEnum nextObject])) {
    if ([curValue hasObject:inObject])
      return;   // found it; nothing to do
  }

  // If it doesn't exist, make one.
  PrefChangeObserverOwner* observerOwner = [[PrefChangeObserverOwner alloc] initWithPrefName:prefName object:inObject];
  [existingObservers addObject:observerOwner];    // takes ownership
  [observerOwner release];
}

- (void)removeObserver:(id)inObject
{
  NSEnumerator* observerArraysEnum = [mPrefChangeObservers objectEnumerator];
  NSMutableArray* curArray;
  while ((curArray = [observerArraysEnum nextObject])) {
    // Look for an existing observer with this target object.
    NSEnumerator* observersEnum = [curArray objectEnumerator];
    PrefChangeObserverOwner* prefObserverOwner = nil;

    PrefChangeObserverOwner* curValue;
    while ((curValue = [observersEnum nextObject])) {
      if ([curValue hasObject:inObject]) {
        prefObserverOwner = curValue;
        break;
      }
    }

    if (prefObserverOwner)
      [curArray removeObjectIdenticalTo:prefObserverOwner];   // This should release it and unregister the observer.
  }
}

- (void)removeObserver:(id)inObject forPref:(const char*)inPrefName
{
  NSString* prefName = [NSString stringWithUTF8String:inPrefName];

  NSMutableArray* existingObservers = [mPrefChangeObservers objectForKey:prefName];
  if (!existingObservers)
    return;

  // Look for an existing observer with this target object.
  NSEnumerator* observersEnum = [existingObservers objectEnumerator];
  PrefChangeObserverOwner* prefObserverOwner = nil;

  PrefChangeObserverOwner* curValue;
  while ((curValue = [observersEnum nextObject])) {
    if ([curValue hasObject:inObject]) {
      prefObserverOwner = curValue;
      break;
    }
  }

  if (prefObserverOwner)
    [existingObservers removeObjectIdenticalTo:prefObserverOwner];   // This should release it and unregister the observer.
}

//
// isFlashblockAllowed
//
// Checks whether Flashblock can be enabled.
// Flashblock is only allowed if JavaScript and plug-ins are both enabled.
// NOTE: This code is duplicated in WebFeatures.mm since the Flashblock checkbox
// settings are done by WebFeatures and stylesheet loading is done by PreferenceManager.
//
- (BOOL)isFlashblockAllowed
{
  BOOL gotPref = NO;
  BOOL jsEnabled = [self getBooleanPref:kGeckoPrefEnableJavascript withSuccess:&gotPref] && gotPref;
  BOOL pluginsEnabled = [self getBooleanPref:kGeckoPrefEnablePlugins withSuccess:&gotPref] || !gotPref;
  BOOL flashPlugInPresent = [self isFlashInstalled];

  return jsEnabled && pluginsEnabled && flashPlugInPresent;
}

//
// migrateOldDownloadPrefs
//
// Migrates from our old Gecko download preferences, which were a mish-mash of all sorts
// of different things, to the standard toolkit prefs (where they exist).
//
-(void)migrateOldDownloadPrefs
{
  BOOL gotPref;

  unsigned int oldCleanupPolicy = [self getIntPref:kOldGeckoPrefDownloadCleanupPolicy withSuccess:&gotPref];
  // The new policy values (0 = on success; 1 = on quit; 2 = manually) are reversed from the old
  // (manually/on quit/on success), so subtract from 2 to translate.
  [self setPref:kGeckoPrefDownloadCleanupPolicy toInt:(gotPref ? (2 - oldCleanupPolicy) : kRemoveDownloadsManually)];

  BOOL oldFocusPref = [self getBooleanPref:kOldGeckoPrefFocusDownloadManagerOnDownload withSuccess:&gotPref];
  // If we failed to get a pref, default to focus-on-download.
  [self setPref:kGeckoPrefFocusDownloadManagerOnDownload toBoolean:(gotPref ? oldFocusPref : YES)];

  BOOL oldStayOpenPref = [self getBooleanPref:kOldGeckoPrefLeaveDownloadManagerOpen withSuccess:&gotPref];
  // The new pref is "close when done" rather than "stay open", so true is now false.
  // If we failed to get a pref, default to keeping the manager open.
  [self setPref:kGeckoPrefCloseDownloadManagerWhenDone toBoolean:(gotPref ? !oldStayOpenPref : NO)];

  BOOL oldDownloadDirectoryPref = [self getBooleanPref:kOldGeckoPrefDownloadToDefaultLocation withSuccess:&gotPref];
  // If we somehow failed to get a pref here, default to dialogless downloads.
  [self setPref:kGeckoPrefDownloadToDefaultLocation toBoolean:(gotPref ? oldDownloadDirectoryPref : YES)];

  BOOL oldProcessDownloadsPref = [self getBooleanPref:kOldGeckoPrefAutoOpenDownloads withSuccess:&gotPref];
  // If we somehow failed to get a pref, default to no processing.
  [self setPref:kGeckoPrefAutoOpenDownloads toBoolean:(gotPref ? oldProcessDownloadsPref : NO)];

  // Now remove all the old prefs so we don't leave cruft in the profile.
  [self clearPref:kOldGeckoPrefDownloadCleanupPolicy];
  [self clearPref:kOldGeckoPrefFocusDownloadManagerOnDownload];
  [self clearPref:kOldGeckoPrefLeaveDownloadManagerOpen];
  [self clearPref:kOldGeckoPrefDownloadToDefaultLocation];
  [self clearPref:kOldGeckoPrefAutoOpenDownloads];
}

//
// migrateOldExternalLoadBehaviorPref
//
// Migrate the old browser.reuse_window pref to browser.link.open_external.
// Camino 2.1's default is "new tab". Earlier versions defaulted to "new window".
//
-(void)migrateOldExternalLoadBehaviorPref
{
  int oldExternalLoadPref = [self getIntPref:kOldGeckoPrefExternalLoadBehavior withSuccess:NULL];

  // Migrate "current window" pref value. All other values ("new window", "new
  // tab", or some unexpected value) are mapped to the new default ("new tab").
  if (oldExternalLoadPref == kOldExternalLoadReusesWindow)
    [self setPref:kGeckoPrefExternalLoadBehavior toInt:kExternalLoadReusesWindow];

  [self clearPref:kOldGeckoPrefExternalLoadBehavior];
}

-(NSString*)internetConfigDownloadDirectoryPref
{
  NSURL* oldDownloadDir = nil;
  ICInstance icInstance;

  OSErr err = ::ICStart(&icInstance, 'XPCM');

  if (err == noErr) {
    // ICFindPrefHandle() crashes when getting the download directory if the
    // download directory has never been specified (e.g. a new user account),
    // bug 265903. To work around this we enumerate through the IC prefs to see
    // if the download directory has been specified before trying to obtain it.
    long numPrefs = 0;
    err = ::ICCountPref(icInstance, &numPrefs);

    if (err == noErr) {
      CFStringRef icKeyRef = CFStringCreateWithPascalString(NULL,
                                                            kICDownloadFolder,
                                                            kCFStringEncodingMacRoman);
      NSString* icDownloadFolderKey = [(NSString*)icKeyRef autorelease];

      for (long i = 0; i < numPrefs; ++i) {
        Str255 key;
        err = ::ICGetIndPref(icInstance, i, key);
        if (err != noErr)
          continue;

        CFStringRef keyStringRef = CFStringCreateWithPascalString(NULL,
                                                                  key,
                                                                  kCFStringEncodingMacRoman);
        NSString* keyString = [(NSString*)keyStringRef autorelease];

        if (![keyString isEqualToString:icDownloadFolderKey])
          continue;

        ICAttr attrs;
        Handle icFolderHandle = NewHandle(0);
        err = ::ICFindPrefHandle(icInstance, kICDownloadFolder, &attrs, icFolderHandle);

        if (err == noErr && icFolderHandle) {
          long aliasSize = GetHandleSize(icFolderHandle) - sizeof(ICFileSpec) + sizeof(AliasRecord);
          AliasHandle aliasHandle = (AliasHandle)NewHandleClear(aliasSize);

          if (aliasHandle) {
            ICFileSpec** fileSpec = (ICFileSpec**)icFolderHandle;
            FSRef ref;
            memset(&ref, 0, sizeof(ref));
            Boolean wasChanged = FALSE;

            HLock(icFolderHandle);
            HLock((Handle)aliasHandle);
            memcpy(*aliasHandle, &((**fileSpec).alias), aliasSize);

            err = FSResolveAlias(NULL, aliasHandle, &ref, &wasChanged);

            if (err == noErr)
              oldDownloadDir = [(NSURL*)CFURLCreateFromFSRef(NULL, &ref) autorelease];

            DisposeHandle((Handle)aliasHandle);
          }            
          DisposeHandle(icFolderHandle);
        }
        break;
      }
    }
    ::ICStop(icInstance);
  }

  return [oldDownloadDir path];
}

- (void)removeProfileURLClassifierDB
{
  NSString* urlClassifierDB = [[self profilePath] stringByAppendingPathComponent:@"urlclassifier3.sqlite"];
  NSFileManager* fileMgr = [NSFileManager defaultManager];
  if ([fileMgr fileExistsAtPath:urlClassifierDB])
    [fileMgr removeFileAtPath:urlClassifierDB handler:nil];
}

- (NSString*)fontNameForGeckoFontName:(NSString*)geckoFontName
{
  nsresult rv;
  nsCOMPtr<nsIFontEnumerator> fontEnum = do_GetService("@mozilla.org/gfx/fontenumerator;1", &rv);
  if (NS_FAILED(rv))
    return nil;

  PRUnichar* geckoName = [geckoFontName createNewUnicodeBuffer];
  PRUnichar* standardNameBuffer = NULL;
  rv = fontEnum->GetStandardFamilyName(geckoName, &standardNameBuffer);
  if (geckoName)
    nsCRT::free(geckoName);
  if (NS_FAILED(rv))
    return nil;

  NSString* standardName = [NSString stringWithPRUnichars:standardNameBuffer];
  if (standardNameBuffer)
    nsCRT::free(standardNameBuffer);

  return standardName;
}

@end
