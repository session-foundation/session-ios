// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

#ifndef __CExceptionHelper_h__
#define __CExceptionHelper_h__

#import <Foundation/Foundation.h>

#define noEscape __attribute__((noescape))

@interface CExceptionHelper: NSObject

+ (BOOL)performSafely:(noEscape void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end

#endif
