/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "SNTCommandController.h"

#include "SNTLogging.h"

#import "MOLCertificate.h"
#import "MOLCodesignChecker.h"
#import "SNTConfigurator.h"
#import "SNTDropRootPrivs.h"
#import "SNTFileInfo.h"
#import "SNTRule.h"
#import "SNTXPCConnection.h"
#import "SNTXPCControlInterface.h"

@interface SNTCommandRule : NSObject<SNTCommand>
@property SNTXPCConnection *daemonConn;
@end

@implementation SNTCommandRule

REGISTER_COMMAND_NAME(@"rule")

+ (BOOL)requiresRoot {
  return YES;
}

+ (BOOL)requiresDaemonConn {
  return YES;
}

+ (NSString *)shortHelpText {
  return @"Manually add/remove rules.";
}

+ (NSString *)longHelpText {
  return (@"Usage: santactl rule [options]\n"
          @"  One of:\n"
          @"    --whitelist: add to whitelist\n"
          @"    --blacklist: add to blacklist\n"
          @"    --silent-blacklist: add to silent blacklist\n"
          @"    --remove: remove existing rule\n"
          @"\n"
          @"  One of:\n"
          @"    --path {path}: path of binary/bundle to add/remove.\n"
          @"                   Will add the hash of the file currently at that path.\n"
          @"    --sha256 {sha256}: hash to add/remove\n"
          @"\n"
          @"  Optionally:\n"
          @"    --certificate: add certificate rule instead of binary\n"
          @"    --message {message}: custom message\n");
}

+ (void)printErrorUsageAndExit:(NSString *)error {
  printf("%s\n\n", [error UTF8String]);
  printf("%s\n", [[self longHelpText] UTF8String]);
  exit(1);
}

+ (void)runWithArguments:(NSArray *)arguments daemonConnection:(SNTXPCConnection *)daemonConn {
  SNTConfigurator *config = [SNTConfigurator configurator];
  if ([config syncBaseURL] != nil) {
    printf("SyncBaseURL is set, rules are managed centrally.\n");
    exit(1);
  }

  SNTRule *newRule = [[SNTRule alloc] init];
  newRule.state = SNTRuleStateUnknown;
  newRule.type = SNTRuleTypeBinary;

  NSString *path;

  // Parse arguments
  for (NSUInteger i = 0; i < arguments.count; ++i) {
    NSString *arg = arguments[i];

    if ([arg caseInsensitiveCompare:@"--whitelist"] == NSOrderedSame) {
      newRule.state = SNTRuleStateWhitelist;
    } else if ([arg caseInsensitiveCompare:@"--blacklist"] == NSOrderedSame) {
      newRule.state = SNTRuleStateBlacklist;
    } else if ([arg caseInsensitiveCompare:@"--silent-blacklist"] == NSOrderedSame) {
      newRule.state = SNTRuleStateSilentBlacklist;
    } else if ([arg caseInsensitiveCompare:@"--remove"] == NSOrderedSame) {
      newRule.state = SNTRuleStateRemove;
    } else if ([arg caseInsensitiveCompare:@"--certificate"] == NSOrderedSame) {
      newRule.type = SNTRuleTypeCertificate;
    } else if ([arg caseInsensitiveCompare:@"--path"] == NSOrderedSame) {
      if (++i > arguments.count - 1) {
        [self printErrorUsageAndExit:@"--path requires an argument"];
      }
      path = arguments[i];
    } else if ([arg caseInsensitiveCompare:@"--sha256"] == NSOrderedSame) {
      if (++i > arguments.count - 1) {
        [self printErrorUsageAndExit:@"--sha256 requires an argument"];
      }
      newRule.shasum = arguments[i];
      if (newRule.shasum.length != 64) {
        [self printErrorUsageAndExit:@"--sha256 requires a valid SHA-256 as the argument"];
      }
    } else if ([arg caseInsensitiveCompare:@"--message"] == NSOrderedSame) {
      if (++i > arguments.count - 1) {
        [self printErrorUsageAndExit:@"--message requires an argument"];
      }
      newRule.customMsg = arguments[i];
    } else {
      [self printErrorUsageAndExit:[@"Unknown argument: " stringByAppendingString:arg]];
    }
  }

  if (path) {
    SNTFileInfo *fi = [[SNTFileInfo alloc] initWithPath:path];
    if (!fi.path) {
      [self printErrorUsageAndExit:@"Provided path was not a plain file"];
    }

    if (newRule.type == SNTRuleTypeBinary) {
      newRule.shasum = fi.SHA256;
    } else if (newRule.type == SNTRuleTypeCertificate) {
      MOLCodesignChecker *cs = [[MOLCodesignChecker alloc] initWithBinaryPath:fi.path];
      newRule.shasum = cs.leafCertificate.SHA256;
    }
  }

  if (newRule.state == SNTRuleStateUnknown) {
    [self printErrorUsageAndExit:@"No state specified"];
  } else if (!newRule.shasum) {
    [self printErrorUsageAndExit:@"Either SHA-256 or path to file must be specified"];
  }

  [[daemonConn remoteObjectProxy] databaseRuleAddRules:@[newRule]
                                            cleanSlate:NO
                                                 reply:^(NSError *error) {
    if (error) {
      printf("Failed to modify rules: %s", [error.localizedDescription UTF8String]);
      LOGD(@"Failure reason: %@", error.localizedFailureReason);
      exit(1);
    } else {
      if (newRule.state == SNTRuleStateRemove) {
        printf("Removed rule for SHA-256: %s.\n", [newRule.shasum UTF8String]);
      } else {
        printf("Added rule for SHA-256: %s.\n", [newRule.shasum UTF8String]);
      }
      exit(0);
    }
  }];
}

@end
