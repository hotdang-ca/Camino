/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "BookmarkImportDlgController.h"
#import "BookmarkManager.h"
#import "BookmarkFolder.h"
#import "MainController.h"
#import "BrowserWindowController.h"
#import "BookmarkViewController.h"
#import "NSFileManager+Utils.h"
#import "NSMenu+Utils.h"

@interface BookmarkImportDlgController (Private)

- (BOOL)tryAddImportFromBrowser:(NSString *)aBrowserName withBookmarkPath:(NSString *)aPath;
- (void)tryFirefoxImport;
- (void)tryOmniWeb5Import;
- (void)buildButtonForBrowser:(NSString *)aBrowserName withPathArray:(NSArray *)anArray;
- (NSString *)saltedBookmarkPathForProfile:(NSString *)aPath;
- (NSString *)saltedPlacesPathForProfile:(NSString *)aPath;
- (void)beginImportFrom:(NSArray *)aPath withTitles:(NSArray *)anArray;
- (void)beginOmniWeb5ImportFrom:(NSArray *)anArray;
- (void)finishImport:(BOOL)success fromFiles:(NSArray *)anArray;
- (void)finishThreadedImport:(BOOL)success fromFiles:(NSArray *)anArray;
- (void)showProgressView;
- (void)showImportView;

@end

#pragma mark -

@implementation BookmarkImportDlgController

- (void)windowDidLoad
{
  [self showImportView];
  [self buildAvailableFileList];
}

// Looks through known bookmark locations of other browsers and populates the import 
// choices with those found.  Must be called when showing the dialog.
- (void)buildAvailableFileList
{
  // Remove everything but the separator and "Select a file..." option, on the off-chance that someone brings
  // up the import dialog, throws away a profile, then brings up the import dialog again
  while ([mBrowserListButton numberOfItems] > 2)
    [mBrowserListButton removeItemAtIndex:0];

  // Look for bookmarks in reverse order of likely usefulness so that the most
  // common browsers' bookmarks are listed at the top of the pop-up.
  [self tryAddImportFromBrowser:@"Internet Explorer" withBookmarkPath:@"~/Library/Preferences/Explorer/Favorites.html"];
  [self tryAddImportFromBrowser:@"iCab 2" withBookmarkPath:@"~/Library/Preferences/iCab Preferences/Hotlist.html"];
  [self tryAddImportFromBrowser:@"iCab 3" withBookmarkPath:@"~/Library/Preferences/iCab Preferences/Hotlist3.html"];
  // iCab 4 uses a plist format, but doesn't put a plist extension on the file.
  [self tryAddImportFromBrowser:@"iCab 4" withBookmarkPath:@"~/Library/Preferences/iCab/iCab 4 Bookmarks"];

  NSString *mozPath = [self saltedBookmarkPathForProfile:@"~/Library/Mozilla/Profiles/default/"];
  if (mozPath)
    [self tryAddImportFromBrowser:@"Netscape/Mozilla/SeaMonkey 1.x" withBookmarkPath:mozPath];

  // SeaMonkey 1.x used the same profile as Netscape/Mozilla; SeaMonkey 2
  // introduced a unique profile location.  SeaMonkey 2.0 used Places history
  // with traditional HTML bookmarks; SeaMonkey 2.1 might introduce Places
  // bookmarks, which will make the "is places.sqlite there" trick fail to 
  // find SeaMonkey 2-only profiles if the trick is incorporated into this
  // check (checking for the "bookmarkbackups" sub-folder should work).
  mozPath = [self saltedBookmarkPathForProfile:@"~/Library/Application Support/SeaMonkey/Profiles/"];
  if (mozPath)
    [self tryAddImportFromBrowser:@"SeaMonkey 2" withBookmarkPath:mozPath];

  if (![self tryAddImportFromBrowser:@"Opera" withBookmarkPath:@"~/Library/Opera/bookmarks.adr"]) {
    if (![self tryAddImportFromBrowser:@"Opera" withBookmarkPath:@"~/Library/Preferences/Opera Preferences/bookmarks.adr"]) {
        [self tryAddImportFromBrowser:@"Opera" withBookmarkPath:@"~/Library/Preferences/Opera Preferences/Bookmarks"];
    }
  }
  [self tryAddImportFromBrowser:@"OmniWeb 4" withBookmarkPath:@"~/Library/Application Support/Omniweb/Bookmarks.html"];
  // OmniWeb 5 has between 0 and 3 bookmark files.
  [self tryOmniWeb5Import];

  // Firefox has multiple historical profile locations and needs special-casing for Firefox 3/Places.
  [self tryFirefoxImport];

  [self tryAddImportFromBrowser:@"Safari" withBookmarkPath:@"~/Library/Safari/Bookmarks.plist"];

  [mBrowserListButton selectItemAtIndex:0];
  [mBrowserListButton synchronizeTitleAndSelectedItem];
}

// Checks for the existence of the specified bookmarks file, and adds an import option for
// the given browser if the file is found.
// Returns YES if an import option was added.
- (BOOL)tryAddImportFromBrowser:(NSString *)aBrowserName withBookmarkPath:(NSString *)aPath
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *fullPathString = [aPath stringByStandardizingPath];
  if ([fm fileExistsAtPath:fullPathString]) {
    [self buildButtonForBrowser:aBrowserName withPathArray:[NSArray arrayWithObject:fullPathString]];
    return YES;
  }
  return NO;
}

// Special treatment for Firefox.  Try from different locations in the reverse 
// order of their introduction.  If the current Firefox profile path contains a
// places.sqlite file, then the bookmarks.html file is either an outdated 
// leftover from Firefox 2 or a default file from a new profile; either way, it
// is not what the user wants imported, so bail (until we can import bookmarks
// from places.sqlite).
- (void)tryFirefoxImport
{
  NSString *currentFirefoxProfileRoot = @"~/Library/Application Support/Firefox/Profiles/";
  NSString *maybePlacesBookmarkPath = [self saltedPlacesPathForProfile:currentFirefoxProfileRoot];
  NSString *fullPathString = [maybePlacesBookmarkPath stringByStandardizingPath];
  BOOL hasPlacesBookmarks = [[NSFileManager defaultManager] fileExistsAtPath:fullPathString];
  if (hasPlacesBookmarks) {
    // There's a places.sqlite file in the current profile, so any bookmarks.html in
    // this profile, or in any older profile location, is old.
    return;
  }
  NSString *foxPath = [self saltedBookmarkPathForProfile:currentFirefoxProfileRoot];
  if (!foxPath)
    foxPath = [self saltedBookmarkPathForProfile:@"~/Library/Firefox/Profiles/default/"];
  if (!foxPath)
    foxPath = [self saltedBookmarkPathForProfile:@"~/Library/Phoenix/Profiles/default/"];

  if (foxPath)
    [self tryAddImportFromBrowser:@"Mozilla Firefox 2" withBookmarkPath:foxPath];
}

// Special treatment for OmniWeb 5
- (void)tryOmniWeb5Import
{
  NSArray *owFiles = [NSArray arrayWithObjects:
    @"~/Library/Application Support/OmniWeb 5/Bookmarks.html",
    @"~/Library/Application Support/OmniWeb 5/Favorites.html",
    @"~/Library/Application Support/OmniWeb 5/Published.html",
    nil];
  NSMutableArray *haveFiles = [NSMutableArray array];
  NSEnumerator *enumerator = [owFiles objectEnumerator];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *aPath, *fullPathString;
  while ((aPath = [enumerator nextObject])) {
    fullPathString = [aPath stringByStandardizingPath];
    if ([fm fileExistsAtPath:fullPathString]) {
      [haveFiles addObject:fullPathString];
    }
  }
  if ([haveFiles count] > 0)
    [self buildButtonForBrowser:@"OmniWeb 5" withPathArray:haveFiles];
}

// Given a Mozilla-like profile, returns the bookmarks.html file in the salt directory
// for the last modified profile, or nil on error
- (NSString *)saltedBookmarkPathForProfile:(NSString *)aPath
{
  // find the last modified profile
  NSString *lastModifiedSubDir = [[NSFileManager defaultManager] lastModifiedSubdirectoryAtPath:aPath];
  return [lastModifiedSubDir stringByAppendingPathComponent:@"bookmarks.html"];
}

// Given a Mozilla-like profile, returns the places.sqlite file in the salt directory
// for the last modified profile, or nil on error
- (NSString *)saltedPlacesPathForProfile:(NSString *)aPath
{
  // find the last modified profile
  NSString *lastModifiedSubDir = [[NSFileManager defaultManager] lastModifiedSubdirectoryAtPath:aPath];
  return [lastModifiedSubDir stringByAppendingPathComponent:@"places.sqlite"];
}

- (void)buildButtonForBrowser:(NSString *)aBrowserName withPathArray:(NSArray *)anArray
{
  [mBrowserListButton insertItemWithTitle:aBrowserName atIndex:0];
  NSMenuItem *browserItem = [mBrowserListButton itemAtIndex:0];
  [browserItem setTarget:self];
  [browserItem setAction:@selector(nullAction:)];
  [browserItem setRepresentedObject:anArray];
}

// keeps browsers turned on
- (IBAction)nullAction:(id)aSender
{
}

- (IBAction)cancel:(id)aSender
{
  [[self window] orderOut:self];
}

- (IBAction)import:(id)aSender
{
  NSMenuItem *selectedItem = [mBrowserListButton selectedItem];
  NSString *titleString;
  if ([[selectedItem title] isEqualToString:@"Internet Explorer"])
    titleString = [NSString stringWithString:NSLocalizedString(@"Imported IE Favorites", nil)];
  else
    titleString = [NSString stringWithFormat:NSLocalizedString(@"Imported %@ Bookmarks", nil), [selectedItem title]];
  // Stupid OmniWeb 5 gets its own import function
  if ([[selectedItem title] isEqualToString:@"OmniWeb 5"]) {
      [self beginOmniWeb5ImportFrom:[selectedItem representedObject]];
  }
  else {
    [self beginImportFrom:[selectedItem representedObject] withTitles:[NSArray arrayWithObject:titleString]];
  }
}

- (IBAction)loadOpenPanel:(id)aSender
{
  NSOpenPanel* openPanel = [NSOpenPanel openPanel];
  [openPanel setCanChooseFiles:YES];
  [openPanel setCanChooseDirectories:NO];
  [openPanel setAllowsMultipleSelection:NO];
  [openPanel setPrompt:NSLocalizedString(@"ImportPanelButton", nil)];
  NSArray* array = [NSArray arrayWithObjects:@"htm", @"html", @"plist", nil];
  [NSMenu cancelAllTracking];
  int result = [openPanel runModalForDirectory:nil
                                          file:nil
                                         types:array];
  if (result == NSOKButton) {
    NSString *pathToFile = [[openPanel filenames] objectAtIndex:0];
    [self beginImportFrom:[NSArray arrayWithObject:pathToFile]
               withTitles:[NSArray arrayWithObject:NSLocalizedString(@"Imported Bookmarks", nil)]];
  }
}

- (void)beginOmniWeb5ImportFrom:(NSArray *)anArray
{
  NSEnumerator *enumerator = [anArray objectEnumerator];
  NSMutableArray *titleArray= [NSMutableArray array];
  NSString* curFilename = nil;
  NSString *curPath = nil;
  while ((curPath = [enumerator nextObject])) {
    curFilename = [curPath lastPathComponent];
    // What folder we import into depends on what OmniWeb file we're importing.
    if ([curFilename isEqualToString:@"Bookmarks.html"])
      [titleArray addObject:NSLocalizedString(@"Imported OmniWeb 5 Bookmarks", nil)];
    else if ([curFilename isEqualToString:@"Favorites.html"])
      [titleArray addObject:NSLocalizedString(@"OmniWeb Favorites", nil)];
    else if ([curFilename isEqualToString:@"Published.html"])
      [titleArray addObject:NSLocalizedString(@"OmniWeb Published", nil)];
  }
  [self beginImportFrom:anArray withTitles:titleArray];
}

- (void)beginImportFrom:(NSArray *)aPathArray withTitles:(NSArray *)aTitleArray
{
  [self showProgressView];
  NSDictionary *aDict = [NSDictionary dictionaryWithObjectsAndKeys:aPathArray, kBookmarkImportPathIndentifier,
    aTitleArray, kBookmarkImportNewFolderNameIdentifier, nil];
  [NSThread detachNewThreadSelector:@selector(importBookmarksThreadEntry:)
                           toTarget:[BookmarkManager sharedBookmarkManager]
                         withObject:aDict];
}

- (void)finishThreadedImport:(BOOL)success fromFile:(NSString *)aFile
{
  if (success) {
    BrowserWindowController* windowController = [(MainController *)[NSApp delegate] openBrowserWindowWithURL:@"about:bookmarks"
                                                                                                 andReferrer:nil
                                                                                                      behind:nil
                                                                                                 allowPopups:NO];
    BookmarkViewController*  bmController = [windowController bookmarkViewController];
    BookmarkFolder *rootFolder = [[BookmarkManager sharedBookmarkManager] bookmarkRoot];
    BookmarkFolder *newFolder = [rootFolder objectAtIndex:([rootFolder count] - 1)];
    [bmController setItemToRevealOnLoad:newFolder];
  }
  else {
    NSBeginAlertSheet(NSLocalizedString(@"ImportFailureTitle", nil),  // title
                      @"",               // default button
                      nil,               // no cancel buttton
                      nil,               // no third button
                      [self window],     // window
                      self,              // delegate
                      @selector(alertSheetDidEnd:returnCode:contextInfo:),
                      nil,               // no dismiss sel
                      (void *)NULL,      // no context
                      [NSString stringWithFormat:NSLocalizedString(@"ImportFailureMessage", nil), aFile]
                      );
  }
  [[self window] orderOut:self];
  [self showImportView];
}

- (void)alertSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
  [[self window] orderOut:self];
}

- (void)showProgressView
{
  NSSize viewSize = [mProgressView frame].size;
  [[self window] setContentView:mProgressView];
  [[self window] setContentSize:viewSize];
  [[self window] center];
  [mImportProgressBar setUsesThreadedAnimation:YES];
  [mImportProgressBar startAnimation:self];
}

- (void)showImportView
{
  [mImportProgressBar stopAnimation:self];
  NSSize viewSize = [mImportView frame].size;
  [[self window] setContentView:mImportView];
  [[self window] setContentSize:viewSize];
  [[self window] center];
}

@end
