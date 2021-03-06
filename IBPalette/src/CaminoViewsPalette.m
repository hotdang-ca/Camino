// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at http://mozilla.org/MPL/2.0/.

//
//  CaminoViewsPalette.m
//  CaminoViewsPalette
//
//  Created by Simon Fraser on 21/11/05.

#import "CaminoViewsPalette.h"

@interface NSObject(PrivateAPI)
+ (BOOL)isInInterfaceBuilder;
@end

@implementation CaminoViewsPalette

- (void)finishInstantiate
{
  [self associateObject:mShrinkWrapView
                        ofType:IBViewPboardType
                        withView:mShrinkWrapViewImageView];

  [self associateObject:mFlippedShrinkWrapView
                        ofType:IBViewPboardType
                        withView:mFlippedShrinkWrapViewImageView];

  [self associateObject:mStackView
                        ofType:IBViewPboardType
                        withView:mStackViewImageView];
}

- (NSString*)toolTipForObject:(id)object
{
  if (object == mShrinkWrapViewImageView)
    return @"CHShrinkWrapView";

  if (object == mFlippedShrinkWrapViewImageView)
    return @"CHFlippedShrinkWrapView";

  if (object == mStackViewImageView)
    return @"CHStackView";

  return @"";
}

@end

#pragma mark -

@implementation NSObject(CaminoViewsPalettePaletteInspector)

+ (BOOL)editingInInterfaceBuilder
{
  return ([self respondsToSelector:@selector(isInInterfaceBuilder)] && [self isInInterfaceBuilder]) &&
         ([NSApp respondsToSelector:@selector(isTestingInterface)] && ![NSApp isTestingInterface]);
}

@end

#pragma mark -

@implementation CHShrinkWrapView(CaminoViewsPalettePaletteInspector)

#if 0
- (NSString *)inspectorClassName
{
    return @"CaminoViewsInspector";
}
#endif

- (BOOL)ibIsContainer
{
  return YES;
}

- (BOOL)ibDrawFrameWhileResizing
{
  return YES;
}

- (id)ibNearestTargetForDrag
{
  return self;
}

- (BOOL)canEditSelf
{
  return YES;
}

- (BOOL)ibShouldShowContainerGuides
{
  return YES;
}

- (BOOL)ibSupportsInsideOutSelection
{
  return YES;
}

@end

#pragma mark -

@implementation CHFlippedShrinkWrapView(CaminoViewsPalettePaletteInspector)

#if 0
- (NSString *)inspectorClassName
{
    return @"CaminoViewsInspector";
}
#endif

- (BOOL)ibIsContainer
{
  return YES;
}

- (BOOL)ibDrawFrameWhileResizing
{
  return YES;
}

- (id)ibNearestTargetForDrag
{
  return self;
}

- (BOOL)canEditSelf
{
  return YES;
}

- (BOOL)ibShouldShowContainerGuides
{
  return YES;
}

- (BOOL)ibSupportsInsideOutSelection
{
  return YES;
}

@end

#pragma mark -

@implementation CHStackView(CaminoViewsPalettePaletteInspector)

#if 0
- (NSString *)inspectorClassName
{
    return @"CaminoViewsInspector";
}
#endif

- (BOOL)ibIsContainer
{
  return YES;
}

- (BOOL)ibDrawFrameWhileResizing
{
  return YES;
}

- (id)ibNearestTargetForDrag
{
  return self;
}

- (BOOL)canEditSelf
{
  return YES;
}

- (BOOL)ibShouldShowContainerGuides
{
  return YES;
}

- (BOOL)ibSupportsInsideOutSelection
{
  return YES;
}

@end

@implementation AutoSizingTextField(CaminoViewsPalettePaletteInspector)

#if 0
- (NSString *)inspectorClassName
{
    return @"CaminoViewsInspector";
}
#endif

- (BOOL)ibDrawFrameWhileResizing
{
  return YES;
}

@end
