/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*-
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "HistoryMenu.h"

#import "NSImage+Utils.h"
#import "NSString+Utils.h"
#import "NSMenu+Utils.h"

#import "MainController.h"
#import "BrowserWindowController.h"
#import "BrowserWrapper.h"
#import "CHBrowserService.h"
#import "PreferenceManager.h"

#import "HistoryItem.h"
#import "HistoryDataSource.h"
#import "HistoryTree.h"

#include <algorithm>


// the maximum number of history entry menuitems to display
static const int kMaxNumHistoryItems = 50;

// the maximum number of "today" items to show on the main menu
static const unsigned int kMaxTodayItems = 12;

// the maximum number of recently closed pages to show
static const unsigned int kMaxRecentlyClosedItems = 20;

// the maximum number of characters in a menu title before cropping it
static const unsigned int kMaxTitleLength = 50;

// this little class manages the singleton history tree, and takes
// care of shutting it down at XPCOM shutdown time.
@interface HistoryTreeOwner : NSObject
{
  HistoryTree* mHistoryTree;
}

+ (HistoryTreeOwner*)sharedHistoryTreeOwner;
+ (HistoryTree*)sharedHistoryTree;

- (HistoryTree*)historyTree;

@end


@implementation HistoryTreeOwner

+ (HistoryTreeOwner*)sharedHistoryTreeOwner
{
  static HistoryTreeOwner* sHistoryOwner = nil;
  if (!sHistoryOwner)
    sHistoryOwner = [[HistoryTreeOwner alloc] init];

  return sHistoryOwner;
}

+ (HistoryTree*)sharedHistoryTree
{
  return [[HistoryTreeOwner sharedHistoryTreeOwner] historyTree];
}

- (id)init
{
  if ((self = [super init])) {
    // register for xpcom shutdown
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(xpcomShutdownNotification:)
                                                 name:kXPCOMShutDownNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [mHistoryTree release];
  [super dealloc];
}

- (void)xpcomShutdownNotification:(NSNotification*)inNotification
{
  [mHistoryTree release];
  mHistoryTree = nil;
}

- (HistoryTree*)historyTree
{
  if (!mHistoryTree) {
    HistoryDataSource* dataSource = [HistoryDataSource sharedHistoryDataSource];
    mHistoryTree = [[HistoryTree alloc] initWithDataSource:dataSource];
    [mHistoryTree setHistoryView:kHistoryViewByDate];
    [mHistoryTree setSortColumnIdentifier:@"last_visit"];
    [mHistoryTree setSortDescending:YES];
  }
  return mHistoryTree;
}

@end // HistoryTreeOwner


#pragma mark -

@interface HistorySubmenu(Private)

- (NSString*)menuItemTitleForHistoryItem:(HistoryItem*)inItem;

- (void)setUpHistoryMenu;
- (void)menuWillBeDisplayed;
- (void)clearHistoryItems;
- (void)rebuildHistoryItems;
- (void)addLastItems;
- (void)historyChanged:(NSNotification*)inNotification;
- (void)menuWillDisplay:(NSNotification*)inNotification;
- (void)openHistoryItem:(id)sender;

@end

#pragma mark -

@implementation HistorySubmenu

- (NSString*)menuItemTitleForHistoryItem:(HistoryItem*)inItem
{
  NSString* itemTitle = [inItem title];
  if ([itemTitle length] == 0)
    itemTitle = [inItem url];

  return [itemTitle stringByTruncatingTo:kMaxTitleLength at:kTruncateAtMiddle];
}

- (id)initWithTitle:(NSString *)inTitle
{
  if ((self = [super initWithTitle:inTitle])) {
    mHistoryItemsDirty = YES;
    [self setUpHistoryMenu];
  }
  return self;
}

// this should only be called after app launch, when the data source is available
- (void)setUpHistoryMenu
{
  // set ourselves up to listen for history changes
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(historyChanged:)
                                               name:kHistoryTreeChangedNotification
                                             object:[HistoryTreeOwner sharedHistoryTree]];

  // Set us up to receive menuNeedsUpdate: callbacks
  [self setDelegate:self];
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [mRootItem release];
  [super dealloc];
}

- (void)setRootHistoryItem:(HistoryItem*)inRootItem
{
  [mRootItem autorelease];
  mRootItem = [inRootItem retain];
}

- (HistoryItem*)rootItem
{
  return mRootItem;
}

- (void)setNumLeadingItemsToIgnore:(int)inIgnoreItems
{
  mNumIgnoreItems = inIgnoreItems;
}

- (void)setNeedsRebuild:(BOOL)needsRebuild
{
  mHistoryItemsDirty = needsRebuild;
}

- (void)historyChanged:(NSNotification*)inNotification
{
  id rootChangedItem = [[inNotification userInfo] objectForKey:kHistoryTreeChangeRootKey];

  // If rootChangedItem is nil, the whole history tree is being rebuilt.
  if (!rootChangedItem) {
    // Clear the now-invalid root item; it will be set again during rebuild.
    [self setRootHistoryItem:nil];
    [self setNeedsRebuild:YES];
  }
  else if (mRootItem == rootChangedItem) {
    [self setNeedsRebuild:YES];
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
  // Contrary to what the docs say, this method is also called whenever a key
  // equivalent is triggered anywhere in the application, so we only update
  // the menu if we are actually doing menu tracking.
  if ([NSMenu currentyInMenuTracking])
    [self menuWillBeDisplayed];
}

- (void)clearHistoryItems
{
  [self removeItemsFromIndex:0];
}

- (void)rebuildHistoryItems
{
  // remove everything after the "before" item
  [self clearHistoryItems];

  // now iterate through the history items
  NSEnumerator* childEnum = [[mRootItem children] objectEnumerator];

  // skip the first mNumIgnoreItems items
  for (int i = 0; i < mNumIgnoreItems; ++i)
    [childEnum nextObject];

  int remainingEntriesToShow = kMaxNumHistoryItems;
  HistoryItem* curChild;
  while (((curChild = [childEnum nextObject])) && remainingEntriesToShow > 0) {
    NSMenuItem* newItem = nil;

    if ([curChild isKindOfClass:[HistorySiteItem class]]) {
      newItem = [[[NSMenuItem alloc] initWithTitle:[self menuItemTitleForHistoryItem:curChild]
                                            action:@selector(openHistoryItem:)
                                     keyEquivalent:@""] autorelease];
      [newItem setImage:[curChild iconAllowingLoad:NO]];
      [newItem setTarget:self];
      [newItem setRepresentedObject:curChild];

      [self addItem:newItem];
      [self addCommandKeyAlternatesForMenuItem:newItem];
      remainingEntriesToShow--;
    }
    else if ([curChild isKindOfClass:[HistoryCategoryItem class]] && ([curChild numberOfChildren] > 0)) {
      NSString* itemTitle = [self menuItemTitleForHistoryItem:curChild];
      newItem = [[[NSMenuItem alloc] initWithTitle:itemTitle
                                            action:nil
                                     keyEquivalent:@""] autorelease];
      [newItem setImage:[curChild iconAllowingLoad:NO]];

      HistorySubmenu* newSubmenu = [[[HistorySubmenu alloc] initWithTitle:itemTitle] autorelease];
      [newSubmenu setRootHistoryItem:curChild];
      [newItem setSubmenu:newSubmenu];

      [self addItem:newItem];
      remainingEntriesToShow--;
    }
  }

  [self addLastItems];

  [self setNeedsRebuild:NO];
}

- (void)addLastItems
{
  if (([[[self rootItem] children] count] - mNumIgnoreItems) > (unsigned)kMaxNumHistoryItems) {
    [self addItem:[NSMenuItem separatorItem]];
    NSMenuItem* showMoreItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"ShowMoreHistoryMenuItem", @"")
                                                           action:@selector(showHistory:)
                                                    keyEquivalent:@""] autorelease];
    [showMoreItem setRepresentedObject:mRootItem];
    [self addItem:showMoreItem];
  }
}

- (void)menuWillBeDisplayed
{
  if (mHistoryItemsDirty)
    [self rebuildHistoryItems];
}

- (BOOL)validateMenuItem:(NSMenuItem*)aMenuItem
{
  BrowserWindowController* browserController = [(MainController *)[NSApp delegate] mainWindowBrowserController];
  SEL action = [aMenuItem action];

  // disable history if a sheet is up
  if (action == @selector(openHistoryItem:))
    return !([browserController shouldSuppressWindowActions]);

  return YES;
}

- (void)openHistoryItem:(id)sender
{
  id repObject = [sender representedObject];
  NSString* itemURL = nil;
  if ([repObject isKindOfClass:[HistoryItem class]])
    itemURL = [repObject url];
  else if ([repObject isKindOfClass:[NSString class]])
    itemURL = repObject;

  if (itemURL) {
    // XXX share this logic with MainController and HistoryOutlineViewDelegate
    BrowserWindowController* bwc = [(MainController *)[NSApp delegate] mainWindowBrowserController];
    if (bwc) {
      if ([sender keyEquivalentModifierMask] & NSCommandKeyMask) {
        BOOL openInTab = [[PreferenceManager sharedInstance] getBooleanPref:kGeckoPrefOpenTabsForMiddleClick
                                                                withSuccess:NULL];
        BOOL backgroundLoad = [BrowserWindowController shouldLoadInBackgroundForDestination:(openInTab ? eDestinationNewTab
                                                                                                       : eDestinationNewWindow)
                                                                                     sender:sender];
        if (openInTab)
          [bwc openNewTabWithURL:itemURL referrer:nil loadInBackground:backgroundLoad allowPopups:NO setJumpback:NO];
        else
          [bwc openNewWindowWithURL:itemURL referrer:nil loadInBackground:backgroundLoad allowPopups:NO];
      }
      else {
        [bwc loadURL:itemURL];
      }
    }
    else {
      [(MainController *)[NSApp delegate] openBrowserWindowWithURL:itemURL andReferrer:nil behind:nil allowPopups:NO];
    }
  }
}

@end


#pragma mark -

@interface TopLevelHistoryMenu(Private)

- (void)appLaunchFinished:(NSNotification*)inNotification;
- (NSMenuItem*)todayMenuItem;

@end

@implementation TopLevelHistoryMenu

- (NSString*)menuItemTitleForHistoryItem:(HistoryItem*)inItem
{
  // Give the "Today" menu a different title, since part of it is pulled out
  // into the top level.
  if ([inItem respondsToSelector:@selector(isTodayCategory)] &&
      [(HistoryDateCategoryItem*)inItem isTodayCategory])
  {
    return NSLocalizedString(@"TopLevelHistoryMenuEarlierToday", nil);
  }

  return [super menuItemTitleForHistoryItem:inItem];
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [mTodayItem release];
  [mRecentlyClosedMenu release];
  [super dealloc];
}

- (void)awakeFromNib
{
  mRecentlyClosedMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"RecentlyClosed", nil)];
  [self setNeedsRebuild:YES];

  // listen for app launch completion
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appLaunchFinished:)
                                               name:NSApplicationDidFinishLaunchingNotification
                                             object:nil];

  // listen for closing pages
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(browserClosed:)
                                               name:kBrowserInstanceClosedNotification
                                             object:nil];
}

- (void)appLaunchFinished:(NSNotification*)inNotification
{
  mAppLaunchDone = YES;
  // set up the history menu after a delay, so that other app launch stuff
  // finishes first
  [self performSelector:@selector(setUpHistoryMenu) withObject:nil afterDelay:0];
}

- (void)setUpHistoryMenu
{
  // Listen for history being cleared.
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(historyCleared:)
             name:kHistoryDataSourceClearedNotification
           object:nil];

  [super setUpHistoryMenu];
}

- (void)browserClosed:(NSNotification*)inNotification
{
  BrowserWrapper* browser = [inNotification object];
  NSString* pageURI = [browser currentURI];

  // Ignore empty pages, as well as things like Bookmarks and History.
  if ([pageURI isBlankURL] || [pageURI hasCaseInsensitivePrefix:@"about:"])
    return;

  NSString* itemTitle = [browser pageTitle];
  if ([itemTitle length] == 0)
    itemTitle = pageURI;
  itemTitle = [itemTitle stringByTruncatingTo:kMaxTitleLength at:kTruncateAtMiddle];

  // If this is the first item being added, mark the menu as needing a rebuild
  // so that the folder will be added.
  if ([mRecentlyClosedMenu numberOfItems] == 0)
    [self setNeedsRebuild:YES];

  NSMenuItem* newItem = [[[NSMenuItem alloc] initWithTitle:itemTitle
                                                    action:@selector(openHistoryItem:)
                                             keyEquivalent:@""] autorelease];
  [newItem setImage:[browser siteIcon]];
  [newItem setTarget:self];
  [newItem setRepresentedObject:pageURI];

  // Add the new item and its alternates at the top of the menu, and figure out
  // how many menu items there are per entry so we can enforce the max correctly.
  [mRecentlyClosedMenu insertItem:newItem atIndex:0];
  int itemsPerEntry = 1 + [mRecentlyClosedMenu addCommandKeyAlternatesForMenuItem:newItem];
  int maxItems = kMaxRecentlyClosedItems * itemsPerEntry;

  // Remove any previous entries with the same URL so we don't have duplicates,
  // then enforce the limit.
  for (int i = [mRecentlyClosedMenu numberOfItems] - 1; i >= itemsPerEntry; --i) {
    if ([[[mRecentlyClosedMenu itemAtIndex:i] representedObject] isEqualToString:pageURI])
      [mRecentlyClosedMenu removeItemAtIndex:i];
  }
  while ([mRecentlyClosedMenu numberOfItems] > maxItems) {
    [mRecentlyClosedMenu removeItemAtIndex:maxItems];
  }
}

- (void)menuWillBeDisplayed
{
  if (mAppLaunchDone) {
    // the root item is nil at launch, and if the history gets totally rebuilt
    if (!mRootItem) {
      HistoryTree* historyTree = [HistoryTreeOwner sharedHistoryTree];
      if (![historyTree rootItem])
        [historyTree buildTree];

      mRootItem = [[historyTree rootItem] retain];
    }
  }

  [super menuWillBeDisplayed];
}

- (void)clearHistoryItems
{
  [self removeItemsAfterItem:mItemBeforeHistoryItems];
}

- (void)rebuildHistoryItems
{
  [super rebuildHistoryItems];

  NSMenuItem* todayMenuItem = [self todayMenuItem];
  [mTodayItem autorelease];
  mTodayItem = [[(HistorySubmenu*)[todayMenuItem submenu] rootItem] retain];

  // Promote the kMaxTodayItems most recent items into the top-level menu.
  unsigned int maxItems = std::min(kMaxTodayItems, [[mTodayItem children] count]);
  if (maxItems > 0) {
    NSArray* latestHistoryItems = [[mTodayItem children] subarrayWithRange:NSMakeRange(0, maxItems)];
    int todayMenuIndex = [self indexOfItem:todayMenuItem];

    NSEnumerator* latestItemsEnumerator = [latestHistoryItems objectEnumerator];
    HistoryItem* historyItem;
    while ((historyItem = [latestItemsEnumerator nextObject])) {
      NSMenuItem* menuItem = [[[NSMenuItem alloc] initWithTitle:[self menuItemTitleForHistoryItem:historyItem]
                                                         action:@selector(openHistoryItem:)
                                                  keyEquivalent:@""] autorelease];
      [menuItem setImage:[historyItem iconAllowingLoad:NO]];
      [menuItem setTarget:self];
      [menuItem setRepresentedObject:historyItem];

      [self insertItem:menuItem atIndex:(todayMenuIndex++)];
      todayMenuIndex += [self addCommandKeyAlternatesForMenuItem:menuItem];
    }

    [self insertItem:[NSMenuItem separatorItem] atIndex:todayMenuIndex];

    // Prevent the "Earlier Today" menu from showing the promoted items,
    // and remove it if nothing is left.
    [(HistorySubmenu*)[todayMenuItem submenu] setNumLeadingItemsToIgnore:maxItems];
    if ([[mTodayItem children] count] <= maxItems) {
      int todayMenuIndex = [self indexOfItem:todayMenuItem];
      [self removeItemAtIndex:todayMenuIndex];
      // If that was the only day folder, we have an extra separator now.
      if ([[self itemAtIndex:todayMenuIndex] isSeparatorItem])
        [self removeItemAtIndex:todayMenuIndex];
    }
  }
}

- (NSMenuItem*)todayMenuItem
{
  NSEnumerator* menuEnumerator = [[self itemArray] objectEnumerator];
  NSMenuItem* menuItem;
  while ((menuItem = [menuEnumerator nextObject])) {
    if ([[menuItem submenu] respondsToSelector:@selector(rootItem)]) {
      HistoryItem* historyItem = [(HistorySubmenu*)[menuItem submenu] rootItem];
      if ([historyItem respondsToSelector:@selector(isTodayCategory)] &&
          [(HistoryDateCategoryItem*)historyItem isTodayCategory])
      {
        return menuItem;
      }
    }
  }
  return nil;
}

- (void)addLastItems
{
  // The History menu already has a separatorItem after "Show History". We only
  // need to add another separatorItem before "Recently Closed" or
  // "Clear History" if the menu also has history items or submenus.
  NSEnumerator* categoryEnum = [[mRootItem children] objectEnumerator];
  HistoryItem* curCategory;
  while ((curCategory = [categoryEnum nextObject])) {
    if ([[curCategory children] count] > 0) {
      [self addItem:[NSMenuItem separatorItem]];
      break;
    }
  }

  // Add the recently closed items menu if there are any.
  if ([mRecentlyClosedMenu numberOfItems] > 0) {
    NSMenuItem* recentlyClosedItem = [self addItemWithTitle:NSLocalizedString(@"RecentlyClosed", nil)
                                                     action:nil
                                              keyEquivalent:@""];
    [recentlyClosedItem setImage:[NSImage osFolderIcon]];
    [self setSubmenu:mRecentlyClosedMenu forItem:recentlyClosedItem];
    [self addItem:[NSMenuItem separatorItem]];
  }

  // At the bottom of the History menu, add a Clear History item.
  NSMenuItem* clearHistoryItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"ClearHistoryMenuItem", @"")
                                                             action:@selector(clearHistory:)
                                                      keyEquivalent:@""] autorelease];
  [self addItem:clearHistoryItem];
}

- (void)historyChanged:(NSNotification*)inNotification
{
  id rootChangedItem =
      [[inNotification userInfo] objectForKey:kHistoryTreeChangeRootKey];

  // If rootChangedItem is nil, the whole history tree is being rebuilt.
  if (!rootChangedItem) {
    [mTodayItem release];
    mTodayItem = nil;
  }
  else if (!mTodayItem || mTodayItem == rootChangedItem) {
    [self setNeedsRebuild:YES];
  }

  [super historyChanged:inNotification];
}

- (void)historyCleared:(NSNotification*)inNotification {
  [mRecentlyClosedMenu release];
  mRecentlyClosedMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"RecentlyClosed", nil)];
}

- (BOOL)hasRecentlyClosedPages {
  return ([mRecentlyClosedMenu numberOfItems] > 0);
}

@end
