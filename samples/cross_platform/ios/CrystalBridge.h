// Crystal Cross-Platform Demo - iOS Bridge Header
//
// Exposes Crystal's exported C functions to Swift.
// Add this as a Bridging Header in your Xcode project:
//   Build Settings > Objective-C Bridging Header > path/to/CrystalBridge.h

#ifndef CRYSTAL_BRIDGE_H
#define CRYSTAL_BRIDGE_H

#include <stdint.h>

int32_t crystal_add(int32_t a, int32_t b);
int32_t crystal_multiply(int32_t a, int32_t b);
int64_t crystal_fibonacci(int32_t n);
int64_t crystal_factorial(int32_t n);
int32_t crystal_get_platform_id(void);
int64_t crystal_power(int32_t base, int32_t exp);

#endif
