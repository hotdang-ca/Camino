/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import <Carbon/Carbon.h>

#import "NSMenu+Utils.h"

#if MAC_OS_X_VERSION_MAX_ALLOWED <= MAC_OS_X_VERSION_10_4
extern NSString *NSMenuDidBeginTrackingNotification;
#endif

static BOOL sSomeMenuIsTracking = NO;

@interface CarbonMenuList : NSObject
{
  NSMutableArray* mList;
}

+ (CarbonMenuList*)instance;
- (id)init;
- (void)dealloc;
- (NSArray*)list;
- (void)menuOpened:(NSValue*)wrappedMenuRef;
- (void)menuClosed:(NSValue*)wrappedMenuRef;
@end

@implementation CarbonMenuList

+ (CarbonMenuList*)instance {
  static CarbonMenuList* sInstance;
  if (!sInstance) {
    sInstance = [[self alloc] init];
  }
  return sInstance;
}

- (id)init {
  if ((self = [super init])) {
    // 16 slots is more than enough, as it's really only possible to wind up
    // with as many open menus as the maximum submenu depth.  Even if the
    // capacity here lowballs it, the array will expand dynamically.
    mList = [[NSMutableArray alloc] initWithCapacity:16];
  }
  return self;
}

- (void)dealloc {
  [mList release];
  [super dealloc];
}

- (NSArray*)list {
  return mList;
}

- (void)menuOpened:(NSValue*)wrappedMenuRef {
  if (![mList containsObject:wrappedMenuRef]) {
    [mList addObject:wrappedMenuRef];
  }
}

- (void)menuClosed:(NSValue*)wrappedMenuRef {
  [mList removeObject:wrappedMenuRef];
}

@end

#pragma mark -

static OSStatus MenuEventHandler(EventHandlerCallRef inHandlerCallRef, EventRef inEvent, void *inUserData)
{
  UInt32 eventKind = GetEventKind(inEvent);
  switch (eventKind) {
    case kEventMenuOpening:
    case kEventMenuClosed:
    {
      MenuRef theCarbonMenu;
      OSStatus err = GetEventParameter(inEvent, kEventParamDirectObject, typeMenuRef, NULL, sizeof(MenuRef), NULL, &theCarbonMenu);
      if (err == noErr) {
        @try {
          NSValue* wrappedRef = [NSValue valueWithPointer:theCarbonMenu];
          if (eventKind == kEventMenuOpening)
            [[CarbonMenuList instance] menuOpened:wrappedRef];
          else if (eventKind == kEventMenuClosed)
            [[CarbonMenuList instance] menuClosed:wrappedRef];
         }
        @catch (id exception) {
          NSLog(@"Caught exception %@", exception);
        }
      }
    }
      break;
  }
  
  // always let the event propagate  
  return eventNotHandledErr;
}

#pragma mark -

@implementation NSMenu(ChimeraMenuUtils)

+ (void)installCarbonMenuWatchers
{
  static BOOL sInstalled = NO;
  
  if (!sInstalled)
  {
    const EventTypeSpec menuEventList[] = {
      { kEventClassMenu, kEventMenuOpening },
      { kEventClassMenu, kEventMenuClosed  }
    };
    
    InstallApplicationEventHandler(NewEventHandlerUPP(MenuEventHandler), 
                                   GetEventTypeCount(menuEventList),
                                   menuEventList, (void*)self, NULL);
    sInstalled = YES;
  }
}

+ (void)setUpMenuTrackingWatch
{
  NSMenu* mainMenu = [NSApp mainMenu];
  // We never remove this observation, but since clearly these notifications
  // can't be fired after the main menu has been dealloc'd, there's no harm.
  // We use the main menu as the delegate because it's a convenient long-lived
  // object.
  [[NSNotificationCenter defaultCenter] addObserver:mainMenu
                                           selector:@selector(rootMenuStartedTracking:)
                                               name:NSMenuDidBeginTrackingNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:mainMenu
                                           selector:@selector(rootMenuFinishedTracking:)
                                               name:NSMenuDidEndTrackingNotification
                                             object:nil];
  [self installCarbonMenuWatchers];
}

- (void)rootMenuStartedTracking:(id)object
{
  sSomeMenuIsTracking = YES;
}

- (void)rootMenuFinishedTracking:(id)object
{
  sSomeMenuIsTracking = NO;
}

+ (BOOL)currentyInMenuTracking
{
  // We can't just use CarbonMenuList's count since it's not always updated in
  // time to be correct during a menuNeedsUpdate: call.
  return sSomeMenuIsTracking;
}

+ (void)cancelAllTracking {
  // This method uses Carbon functions to do its dirty work, which is
  // hacky but seems to work.  There isn't really a good Cocoa substitute for
  // CancelMenuTracking.  In Leopard, there's -[NSMenu cancelMenuTracking],
  // but that doesn't seem to work to stop menu tracking when a sheet is
  // about to be displayed.  Perhaps that's because it tries to fade the
  // menu out, as CancelMenuTracking would do with |false| as its second
  // argument.  (That doesn't work either.)

  // Stop tracking the menu bar.  Even though the CarbonMenuList contains
  // the menu bar's submenus, it doesn't contain the menu bar itself, and
  // CancelMenuTracking will only stop tracking if called with the same
  // MenuRef used for MenuSelect.  For menu bar pull-down menu tracking,
  // that's the menu bar.
  MenuRef rootMenu = AcquireRootMenu();
  CancelMenuTracking(rootMenu, true, 0);
  DisposeMenu(rootMenu);

  // Stop tracking other types of menus, like pop-ups and contextual menus.
  NSArray* list = [[CarbonMenuList instance] list];
  for (unsigned int index = 0; index < [list count]; ++index) {
    MenuRef menuRef = [(NSValue*)[list objectAtIndex:index] pointerValue];
    CancelMenuTracking(menuRef, true, 0);
  }
}

- (void)checkItemWithTag:(int)tag uncheckingOtherItems:(BOOL)uncheckOthers
{
  if (uncheckOthers)
  {
    NSEnumerator* itemsEnum = [[self itemArray] objectEnumerator];
    NSMenuItem* curItem;
    while ((curItem = (NSMenuItem*)[itemsEnum nextObject]))
      [curItem setState:NSOffState];
  }
  [[self itemWithTag:tag] setState:NSOnState];
}

- (void)checkItemWithTag:(int)unmaskedTag inGroupWithMask:(int)tagMask
{
  NSEnumerator* itemsEnum = [[self itemArray] objectEnumerator];
  NSMenuItem* curItem;
  while ((curItem = (NSMenuItem*)[itemsEnum nextObject]))
  {
    int itemTag = [curItem tag];
    if ((itemTag & tagMask) == tagMask)
    {
      int rawTag = (itemTag & ~tagMask);
      [curItem setState:(rawTag == unmaskedTag) ? NSOnState : NSOffState];
    }
  }
}

- (NSMenuItem*)firstCheckedItem
{
  NSEnumerator* itemsEnumerator = [[self itemArray] objectEnumerator];
  NSMenuItem* currentItem;
  while ((currentItem = [itemsEnumerator nextObject])) {
    if ([currentItem state] == NSOnState)
      return currentItem;
  }
  return nil;
}

- (void)setAllItemsEnabled:(BOOL)inEnable startingWithItemAtIndex:(int)inFirstItem includingSubmenus:(BOOL)includeSubmenus
{
  NSArray* menuItems = [self itemArray];

  unsigned int i;
  for (i = inFirstItem; i < [menuItems count]; i ++)
  {
    NSMenuItem* curItem = [self itemAtIndex:i];
    [curItem setEnabled:inEnable];
    if (includeSubmenus && [curItem hasSubmenu])
    {
      [[curItem submenu] setAllItemsEnabled:inEnable startingWithItemAtIndex:0 includingSubmenus:includeSubmenus];
    }
  }
}

- (NSMenuItem*)itemWithTarget:(id)anObject andAction:(SEL)actionSelector
{
  int itemIndex = [self indexOfItemWithTarget:anObject andAction:actionSelector];
  return (itemIndex == -1) ? (NSMenuItem*)nil : [self itemAtIndex:itemIndex];
}

- (void)removeItemsAfterItem:(NSMenuItem*)inItem
{
  int firstItemToRemoveIndex = 0;

  if (inItem)
    firstItemToRemoveIndex = [self indexOfItem:inItem] + 1;

  [self removeItemsFromIndex:firstItemToRemoveIndex];
}

- (void)removeItemsFromIndex:(int)inItemIndex
{
  if (inItemIndex < 0)
    inItemIndex = 0;

  while ([self numberOfItems] > inItemIndex)
    [self removeItemAtIndex:inItemIndex];
}

- (void)removeAllItemsWithTag:(int)tagToRemove
{
  NSEnumerator* reverseItemEnumerator = [[self itemArray] reverseObjectEnumerator];
  NSMenuItem* menuItem = nil;
  while ((menuItem = [reverseItemEnumerator nextObject])) {
    if ([menuItem tag] == tagToRemove)
      [self removeItem:menuItem];
  }
}

- (int)addCommandKeyAlternatesForMenuItem:(NSMenuItem *)inMenuItem
{
  // Find the item we are adding alternates for. Since this is generally used
  // when building a menu, check the last item first as an optimization.
  int itemIndex = [self numberOfItems] - 1;
  if (![[self itemAtIndex:itemIndex] isEqual:inMenuItem])
    itemIndex = [self indexOfItem:inMenuItem];
  if (itemIndex == -1)
    return 0;

  [inMenuItem setKeyEquivalentModifierMask:0]; // Needed since by default NSMenuItems have NSCommandKeyMask

  NSString* title = [inMenuItem title];
  SEL action = [inMenuItem action];
  id target = [inMenuItem target];
  id representedObject = [inMenuItem representedObject];
  NSImage* image = [inMenuItem image];

  NSMenuItem* altMenuItem = [[NSMenuItem alloc] initAlternateWithTitle:title
                                                                action:action
                                                                target:target
                                                             modifiers:NSCommandKeyMask];
  [altMenuItem setRepresentedObject:representedObject];
  [altMenuItem setImage:image];
  [self insertItem:altMenuItem atIndex:(itemIndex + 1)];
  [altMenuItem release];

  altMenuItem = [[NSMenuItem alloc] initAlternateWithTitle:title
                                                    action:action
                                                    target:target
                                                 modifiers:(NSCommandKeyMask | NSShiftKeyMask)];
  [altMenuItem setRepresentedObject:representedObject];
  [altMenuItem setImage:image];
  [self insertItem:altMenuItem atIndex:(itemIndex + 2)];
  [altMenuItem release];

  return 2;
}

- (void)updateCommandKeyAlternatesForMenuItem:(NSMenuItem *)inMenuItem
{
  int itemIndex = [self indexOfItem:inMenuItem];
  // If the item is not in this menu, there's nothing to update.
  if (itemIndex == -1)
    return;

  id representedObject = [inMenuItem representedObject];
  itemIndex++;
  while (itemIndex < [self numberOfItems]) {
    NSMenuItem* altItem = [self itemAtIndex:itemIndex];
    if ([altItem representedObject] != representedObject)
      break;

    [altItem setTitle:[inMenuItem title]];
    [altItem setImage:[inMenuItem image]];
    itemIndex++;
  }
}

@end


@implementation NSMenuItem(ChimeraMenuItemUtils)

- (id)initAlternateWithTitle:(NSString *)title action:(SEL)action target:(id)target modifiers:(int)modifiers
{
  if ((self = [self initWithTitle:title action:action keyEquivalent:@""])) {
    [self setTarget:target];
    [self setKeyEquivalentModifierMask:modifiers];
    [self setAlternate:YES];
  }

  return self;
}

+ (NSMenuItem *)alternateMenuItemWithTitle:(NSString *)title action:(SEL)action target:(id)target modifiers:(int)modifiers
{
  return [[[NSMenuItem alloc] initAlternateWithTitle:title action:action target:target modifiers:modifiers] autorelease];
}

- (int)tagRemovingMask:(int)tagMask
{
  return ([self tag] & ~tagMask);
}

- (void)takeStateFromItem:(NSMenuItem*)inItem
{
  [self setTitle:[inItem title]];
  [self setEnabled:[inItem isEnabled]];
}

- (BOOL)isDescendantOfMenu:(NSMenu*)aMenu
{
  NSMenu* ancestor = [self menu];
  while (ancestor) {
    if (ancestor == aMenu)
      return YES;
 
    ancestor = [ancestor supermenu];
  }
  return NO;
}

@end
