// Pins the accent and highlight colours AppKit draws with in the test process, before any test runs.
// AppKit reads the accent once, when the app object is first made, so this can't wait for a test:
// a constructor runs when xctest loads the test bundle. Argument domain only: in memory, this
// process only, never saved, so the Mac's own settings are untouched. See `pinnedAccent` in
// TestSupport.swift, which assertSnapshot checks.
#import <Foundation/Foundation.h>
#import "TestColorPin.h"

__attribute__((constructor)) static void DictationTestsPinSystemColors(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *arguments = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [NSMutableDictionary dictionary];
    arguments[@"AppleAccentColor"] = @4;  // blue
    arguments[@"AppleHighlightColor"] = @"0.698039 0.843137 1.000000 Blue";
    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
}

int TestColorPinLinked(void) { return 1; }
