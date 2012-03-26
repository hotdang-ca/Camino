/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "SafeBrowsingTestDataUpdater.h"
#include "nsIUrlClassifierDBService.h"
#include "nsCOMPtr.h"
#include "nsIServiceManager.h"
#include "nsPrintfCString.h"
#include "nsString.h"

// URLs are separated by a comma and should only include the second-level domain name
// (e.g. leave out the "http://www.")
static NSString *const kTestPhishingURLs = @"mozilla.com/firefox/its-a-trap.html,caminobrowser.org/documentation/security/test-phishing/";
static NSString *const kTestMalwareURLs = @"mozilla.com/firefox/its-an-attack.html,caminobrowser.org/documentation/security/test-malware/";

NS_IMPL_ISUPPORTS1(CHSafeBrowsingTestDataUpdater, nsIUrlClassifierUpdateObserver)

CHSafeBrowsingTestDataUpdater::CHSafeBrowsingTestDataUpdater()
{
}

CHSafeBrowsingTestDataUpdater::~CHSafeBrowsingTestDataUpdater()
{
}

NS_IMETHODIMP
CHSafeBrowsingTestDataUpdater::InsertTestURLsIntoSafeBrowsingDb()
{
  nsresult rv;

  nsCOMPtr<nsIUrlClassifierDBService> dbService = do_GetService("@mozilla.org/url-classifier/dbservice;1", &rv);
  NS_ENSURE_SUCCESS(rv, rv);

  nsCAutoString updateStream;
  AppendUpdateStream(NS_LITERAL_CSTRING("test-phish-simple"),
                     [kTestPhishingURLs componentsSeparatedByString:@","],
                     updateStream);

  AppendUpdateStream(NS_LITERAL_CSTRING("test-malware-simple"),
                     [kTestMalwareURLs componentsSeparatedByString:@","],
                     updateStream);

  rv = dbService->BeginUpdate(this, NS_LITERAL_CSTRING("test-phish-simple,test-malware-simple"), NS_LITERAL_CSTRING(""));
  NS_ENSURE_SUCCESS(rv, rv);
  rv = dbService->BeginStream(NS_LITERAL_CSTRING(""), NS_LITERAL_CSTRING(""));
  NS_ENSURE_SUCCESS(rv, rv);
  rv = dbService->UpdateStream(updateStream);
  NS_ENSURE_SUCCESS(rv, rv);
  rv = dbService->FinishStream();
  NS_ENSURE_SUCCESS(rv, rv);
  rv = dbService->FinishUpdate();
  NS_ENSURE_SUCCESS(rv, rv);

  return NS_OK;
}

nsresult CHSafeBrowsingTestDataUpdater::AppendUpdateStream(const nsACString & inDatabaseTableName,
                                                           NSArray *inTestURLs,
                                                           nsACString & outUpdateStream)
{
  // Form an update stream using the format described at:
  // http://code.google.com/p/google-safe-browsing/wiki/Protocolv2Spec

  nsCAutoString updateStream;
  updateStream.AppendLiteral("\nn:1000\ni:");
  updateStream.Append(inDatabaseTableName);
  updateStream.AppendLiteral("\nad:1-");
  updateStream.AppendInt([inTestURLs count]);
  for (unsigned i = 0; i < [inTestURLs count]; i++) {
    const char *currentURL = [[inTestURLs objectAtIndex:i] cStringUsingEncoding:NSASCIIStringEncoding];
    updateStream.Append(nsPrintfCString("\na:%i:32:%i\n", i + 1, strlen(currentURL)));
    updateStream.Append(currentURL);
  }

  outUpdateStream.Append(updateStream);

  return NS_OK;
}

/* void updateUrlRequested (in ACString url, in ACString table, in ACString serverMAC); */
NS_IMETHODIMP CHSafeBrowsingTestDataUpdater::UpdateUrlRequested(const nsACString & url, const nsACString & table, const nsACString & serverMAC)
{
  return NS_OK;
}

/* void rekeyRequested (); */
NS_IMETHODIMP CHSafeBrowsingTestDataUpdater::RekeyRequested()
{
  return NS_OK;
}

/* void streamFinished (in nsresult status, in unsigned long delay); */
NS_IMETHODIMP CHSafeBrowsingTestDataUpdater::StreamFinished(nsresult status, PRUint32 delay)
{
  return NS_OK;
}

/* void updateError (in nsresult error); */
NS_IMETHODIMP CHSafeBrowsingTestDataUpdater::UpdateError(nsresult error)
{
  NSLog(@"Error inserting test URLs into safe browsing database");
  return NS_OK;
}

/* void updateSuccess (in unsigned long requestedTimeout); */
NS_IMETHODIMP CHSafeBrowsingTestDataUpdater::UpdateSuccess(PRUint32 requestedTimeout)
{
  return NS_OK;
}
