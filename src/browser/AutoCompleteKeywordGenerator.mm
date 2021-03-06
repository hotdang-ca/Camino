/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "AutoCompleteKeywordGenerator.h"

#import "Bookmark.h"

@interface AutoCompleteKeywordGenerator (Private)
// Generates keywords for the given URL.
- (NSArray*)keyArrayForURL:(NSString*)url;

// Returns a URL string with the given scheme replaced by its placeholder
// character. If there is no placeholder for the given character, returns nil.
//
// This makes URLs more suitable for a trie-based autocomplete, both because
// the trie can store the scheme as a single entry (especially important if
// the trie is depth-limited), and because scheme prefixes won't pollute
// autocomplete results (e.g., 'h' won't return every web URL).
- (NSString*)urlStringWithPlaceholder:(NSString*)url
                            forScheme:(NSString*)scheme;

// Creates a unicode character mapping for |scheme| if it doesn't already exist.
- (void)ensureUnicodeCharacterForScheme:(NSString*)scheme;

// Returns the unicode placeholder for the given scheme, or nil if there is
// no mapping.
- (NSString*)unicodeCharacterForScheme:(NSString*)scheme;

// Returns the portion of |url| that comes after |host| (generally the port if
// any, the path, and the query string). If |host| can't be found, returns nil.
- (NSString*)fragmentOfURL:(NSString*)url afterHost:(NSString*)host;
@end

@implementation AutoCompleteKeywordGenerator

- (id)init
{
  if ((self = [super init])) {
    mSchemeToPlaceholderMap = [[NSMutableDictionary alloc] init];
    mGeneratesTitleKeywords = YES;
  }
  return self;
}

- (void)dealloc
{
  [mSchemeToPlaceholderMap release];
  [super dealloc];
}

// TODO: Make a protocol or base class for "persistent site references", and
// have both history and bookmarks implement/use that, to avoid having to know
// about specific classes here.
- (NSArray*)keywordsForItem:(id)item
{
  NSMutableArray* keys = [NSMutableArray array];

  // As a short-term measure, allow users to disable use of titles as a data
  // source by setting a hidden pref. 
  // TODO: Remove this check and associated prefs-fetching code in
  // AutoCompleteDataSource once we have implemented learning and improved
  // scoring.
  if (mGeneratesTitleKeywords) {
    [keys addObjectsFromArray:[[[item valueForKey:@"title"] lowercaseString]
                                  componentsSeparatedByString:@" "]];
  }
  [keys addObjectsFromArray:[self keyArrayForURL:[item valueForKey:@"url"]]];
  if ([item isKindOfClass:[Bookmark class]] && [[item shortcut] length])
    [keys addObject:[item shortcut]];
  return keys;
}

- (void)setGeneratesTitleKeywords:(BOOL)useTitles
{
  mGeneratesTitleKeywords = useTitles;
}

- (NSArray*)keyArrayForURL:(NSString*)url
{
  NSString* lowercaseURL = [url lowercaseString];
  NSMutableArray* urls = [NSMutableArray array];

  // First, convert the url's scheme, if it has one, to a placeholder unicode
  // character. If there's no scheme (including if NSURL doesn't consider the
  // URL valid) insert the whole string.
  NSURL* nsURL = [NSURL URLWithString:lowercaseURL];
  NSString* scheme = [nsURL scheme];
  if (scheme) {
    [self ensureUnicodeCharacterForScheme:scheme];
    NSString* urlWithSchemePlaceholder =
        [self urlStringWithPlaceholder:lowercaseURL forScheme:scheme];
    if (urlWithSchemePlaceholder)
      [urls addObject:urlWithSchemePlaceholder];
  }
  else {
    [urls addObject:lowercaseURL];
  }

  NSString* host = [nsURL host];
  if (host) {
    // If a host is found, we iterate through each domain fragment and add a
    // copy of the URL beginning with that fragment to the array. This allows
    // matches to any fragment of the domain. The top level domain should be
    // ignored since we don't want to match to it. However, currently
    // we just ignore the final part of the URL after the last dot, so we'll
    // over-match for two-part TLDs such as co.uk.
    NSString* restOfURL = [self fragmentOfURL:lowercaseURL afterHost:host];
    // If we can't figure out what the rest of the URL is, just use the host
    // without it, so it will at least match short search strings.
    if (!restOfURL)
      restOfURL = @"";
    NSRange nextDot;
    while ((nextDot = [host rangeOfString:@"."]).location != NSNotFound) {
      [urls addObject:[host stringByAppendingString:restOfURL]];
      host = [host substringFromIndex:NSMaxRange(nextDot)];
    }
  }
  return urls;
}

- (NSArray*)searchTermsForString:(NSString*)searchString
{
  NSString *lowercaseSearchString = [searchString lowercaseString];
  NSArray *searchTerms =
      [lowercaseSearchString componentsSeparatedByString:@" "];

  // If it is likely a URL with a scheme, use the placeholder version.
  // This uses a conservative heuristic based on whether or not the scheme
  // has already been seen, in order to avoid breaking title queries containing
  // a ':'.
  if ([searchTerms count] == 1) {
    NSString* scheme = [[NSURL URLWithString:lowercaseSearchString] scheme];
    NSString *searchStringWithSchemePlaceholder = scheme ?
        [self urlStringWithPlaceholder:lowercaseSearchString forScheme:scheme] :
        nil;
    if (searchStringWithSchemePlaceholder)
      searchTerms = [NSArray arrayWithObject:searchStringWithSchemePlaceholder];
  }
  return searchTerms;
}

- (NSString*)urlStringWithPlaceholder:(NSString*)url
                            forScheme:(NSString*)scheme
{
  NSMutableString* schemelessURL = [[url mutableCopy] autorelease];
  [schemelessURL deleteCharactersInRange:NSMakeRange(0, [scheme length])];
  if ([schemelessURL hasPrefix:@"://"])
    [schemelessURL deleteCharactersInRange:NSMakeRange(0, 3)];
  else if ([schemelessURL hasPrefix:@":"])
    [schemelessURL deleteCharactersInRange:NSMakeRange(0, 1)];

  NSString* placeholder = [self unicodeCharacterForScheme:scheme];
  if (!placeholder)
    return nil;

  return [placeholder stringByAppendingString:schemelessURL];
}

- (void)ensureUnicodeCharacterForScheme:(NSString*)scheme
{
  if ([mSchemeToPlaceholderMap objectForKey:scheme])
    return;

  // Each new scheme encountered is given the next available character from
  // the first Unicode Private Use Area.
  NSString* placeholder = [NSString stringWithFormat:@"%C",
                             0xE000 + [mSchemeToPlaceholderMap count]];
  [mSchemeToPlaceholderMap setObject:placeholder forKey:scheme];
}

- (NSString*)unicodeCharacterForScheme:(NSString*)scheme
{
  return [mSchemeToPlaceholderMap objectForKey:scheme];
}

- (NSString*)fragmentOfURL:(NSString*)url afterHost:(NSString*)host
{
  NSRange rangeOfHost = [url rangeOfString:host];
  if (rangeOfHost.location == NSNotFound) {
    // If there's no match, it's probably because |host| is unescaped but
    // url isn't; try again with an escaped version of the host.
    NSString* escapedHost =
        [[host stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]
            lowercaseString];
    rangeOfHost = [url rangeOfString:escapedHost];
  }
  if (rangeOfHost.location == NSNotFound)
    return nil;
  return [url substringFromIndex:NSMaxRange(rangeOfHost)];
}

@end
